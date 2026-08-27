/**
 * @file Moon grammar for tree-sitter
 * @license MIT
 *
 * This grammar mirrors the Moon compiler front-end in the parent repository:
 *   - lexical rules track  src/lexer.zig  and  src/token.zig  (the `Tag` enum),
 *   - syntactic rules and operator precedence track  src/parser.zig  and the
 *     `## Formal Grammar` (EBNF) section of  moon.md.
 *
 * Keep it in sync with those files; the token set in particular should always
 * match `src/token.zig`'s `Tag`.
 */

/* eslint-disable arrow-parens */
/* eslint-disable camelcase */
/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

// Binary operator precedence, lifted directly from parser.zig `binPrec`.
// Higher number binds tighter. Note two Moon-specific quirks that this grammar
// faithfully reproduces:
//   * `|` (bitwise or) lives at the EQUALITY level (3), not below `&`/`^`.
//   * `..` (range) lives at the COMPARISON level (5).
// Every binary operator is left-associative (parser.zig calls
// `parseBinary(prec + 1)` for the right operand).
const PREC = {
  or: 1,        // ||
  and: 2,       // &&
  equality: 3,  // == != |
  bitand: 4,    // & ^
  compare: 5,   // < <= > >= << >> ..
  additive: 6,  // + -
  multiplicative: 7, // * / %
  unary: 8,     // - ! & * await   (prefix)
  cast: 9,      // expr as Type
  postfix: 10,  // call, index, field, ?, turbofish
  // Highest band: primary expressions (literals, names, paths, struct/array/
  // dict literals, some/none/ok/err). Not part of the operator ladder; used to
  // keep these tighter than the binary operators above.
  primary: 11,
};

module.exports = grammar({
  name: 'moon',

  // `//` line comments and `/* */` block comments may appear between any two
  // tokens; whitespace too.
  extras: $ => [
    /\s/,
    $.line_comment,
    $.block_comment,
  ],

  // `block_comment` is scanned by src/scanner.c because Moon's block comments
  // NEST (lexer.zig) and a regex cannot balance `/* */` pairs.
  externals: $ => [
    $.block_comment,
  ],

  // Keyword extraction: identifiers and keywords share a lexical class, so tell
  // tree-sitter the identifier rule that owns the keyword tokens.
  word: $ => $.identifier,

  supertypes: $ => [
    $._item,
    $._expression,
    $._pattern,
    $._type,
    $._statement,
    $._literal,
  ],

  // Genuine ambiguities resolved by GLR rather than precedence. Each pairing is
  // a place where the same prefix can begin two different constructs and the
  // parser must look further ahead than a single token.
  conflicts: $ => [
    // `Name { ... }` is a struct literal expression OR `Name` followed by a
    // block (e.g. a control-flow body). parser.zig disambiguates with
    // `isStructLiteralStart` + the `allow_struct_lit` flag. The declared
    // conflict keeps both GLR stacks alive; `_control_expression` (which omits
    // struct literals) plus the negative dynamic precedence on `struct_literal`
    // then select the condition-and-block reading in `if`/`while`/`for`/`match`
    // heads, while ordinary positions still read the struct literal.
    [$.struct_literal, $._expression],
    [$._control_expression, $.struct_literal],
    // At block start, `name:` can begin either a dictionary entry or a loop
    // label; the following `while`/`for` selects the latter.
    [$.loop_label, $._expression],
    // `use a.b`: the trailing `b` is either another path segment or a
    // single-import tail (`use_single`). They diverge only at `as`/end of item.
    [$.use_path, $.use_single],
    // `f < T` begins either a comparison or the type arguments of `f<T>(..)`.
    // Only the `(` after the closing `>` tells them apart, which is further
    // than precedence can look — and a prefix operator on the callee (`*p<T>()`
    // vs `*p < q`) has to stay undecided for exactly as long.
    [$.binary_expression, $.turbofish_call_expression],
    [$.unary_expression, $.binary_expression, $.turbofish_call_expression],
    [$.dereference_expression, $.binary_expression, $.turbofish_call_expression],
    [$.await_expression, $.binary_expression, $.turbofish_call_expression],
    [$.address_of_expression, $.binary_expression, $.turbofish_call_expression],
    // Inside an undecided `f < x …`, whatever follows the `<` is either a type
    // or the right operand of the comparison, and both spell a name the same
    // way — as they do a parenthesised list (`(A, B)` vs `(a, b)`).
    [$.generic_type, $._expression],
    [$.tuple_type, $.tuple_expression],
  ],

  rules: {
    // -- program / items --------------------------------------------------
    program: $ => repeat($._item),

    _item: $ => choice(
      $.function_definition,
      $.extern_function,
      $.struct_definition,
      $.enum_definition,
      $.type_alias,
      $.const_definition,
      $.use_declaration,
      $.interface_definition,
      $.impl_definition,
      $.directive,
    ),

    visibility: _ => 'pub',

    // fn / async fn / const fn share one rule; the modifier is optional.
    function_definition: $ => seq(
      optional($.visibility),
      optional(choice('async', 'const')),
      'fn',
      field('name', $.identifier),
      optional($.type_parameters),
      field('parameters', $.parameter_list),
      optional($.return_type),
      field('body', $.block),
    ),

    extern_function: $ => seq(
      optional($.visibility),
      'extern',
      'fn',
      // method_ident ::= IDENT | "let"
      field('name', choice($.identifier, 'let')),
      optional($.type_parameters),
      field('parameters', $.extern_parameter_list),
      optional($.return_type),
    ),

    parameter_list: $ => seq(
      '(',
      optional(seq(
        $.parameter,
        repeat(seq(',', $.parameter)),
        optional(','),
      )),
      ')',
    ),

    // extern signatures additionally allow a trailing `...` (C varargs), or a
    // lone `...`.
    extern_parameter_list: $ => seq(
      '(',
      optional(choice(
        $.variadic,
        seq(
          $.parameter,
          repeat(seq(',', $.parameter)),
          optional(seq(',', $.variadic)),
          optional(','),
        ),
      )),
      ')',
    ),

    variadic: _ => '...',

    // `...` before the type marks a collect-variadic final parameter; `= expr`
    // is a default value (plan 09). Extern signatures use the bare trailing
    // `...` of extern_parameter_list instead and take no defaults (the parser
    // enforces both; the grammar stays permissive).
    parameter: $ => seq(
      field('name', $.identifier),
      ':',
      optional($.variadic),
      field('type', $._type),
      optional(seq('=', field('default', $._expression))),
    ),

    return_type: $ => seq('->', field('type', $._type)),

    // type_params ::= "<" type_param ("," type_param)* ","? ">"
    // type_param  ::= IDENT (":" IDENT ("+" IDENT)*)?  — an optional interface
    // bound list (`<T: Weight>`, `<T: A + B>`), mirroring parser.zig's
    // `parseTypeParams`.
    type_parameters: $ => seq(
      '<',
      $.type_parameter,
      repeat(seq(',', $.type_parameter)),
      optional(','),
      '>',
    ),

    type_parameter: $ => seq(
      field('name', $.identifier),
      optional(seq(
        ':',
        field('bound', $.identifier),
        repeat(seq('+', field('bound', $.identifier))),
      )),
    ),

    // struct_def ::= struct_attr* visibility? "struct" IDENT type_params? body
    // Layout attributes precede visibility (`@C pub struct ...`); parser.zig
    // reads `@C`/`@packed` before the `pub` modifier. `repeat` (not `repeat1`)
    // keeps the plain `struct` and `pub struct` forms.
    struct_definition: $ => seq(
      repeat($.struct_attribute),
      optional($.visibility),
      'struct',
      field('name', $.identifier),
      optional($.type_parameters),
      field('body', $.field_declaration_list),
    ),

    // `@C` / `@packed` layout attributes. Written `@` immediately followed by
    // the name; the lexer emits `@` then an identifier.
    struct_attribute: $ => seq('@', choice('C', 'packed')),

    field_declaration_list: $ => seq(
      '{',
      optional(seq(
        $.field_declaration,
        repeat(seq(',', $.field_declaration)),
        optional(','),
      )),
      '}',
    ),

    field_declaration: $ => seq(
      field('name', $.identifier),
      ':',
      field('type', $._type),
    ),

    enum_definition: $ => seq(
      optional($.visibility),
      'enum',
      field('name', $.identifier),
      optional($.type_parameters),
      field('body', $.variant_list),
    ),

    variant_list: $ => seq(
      '{',
      optional(seq(
        $.variant,
        repeat(seq(',', $.variant)),
        optional(','),
      )),
      '}',
    ),

    variant: $ => seq(
      field('name', $.identifier),
      optional(seq(
        '(',
        optional($._type_list),
        ')',
      )),
    ),

    type_alias: $ => seq(
      optional($.visibility),
      'type',
      field('name', $.identifier),
      optional($.type_parameters),
      '=',
      field('type', $._type),
    ),

    // const_def ::= visibility? ("let" | "const") IDENT (":" type)? "=" expr
    const_definition: $ => seq(
      optional($.visibility),
      choice('let', 'const'),
      field('name', $.identifier),
      optional(seq(':', field('type', $._type))),
      '=',
      field('value', $._expression),
    ),

    // -- use --------------------------------------------------------------
    use_declaration: $ => seq(
      optional($.visibility),
      'use',
      $.use_path,
    ),

    use_path: $ => seq(
      $._name,
      repeat(seq('.', $._name)),
      optional(seq('.', $.use_tail)),
    ),

    use_tail: $ => choice(
      $.use_wildcard,
      $.use_single,
      $.use_group,
    ),

    use_wildcard: _ => '*',

    use_single: $ => seq($._name, optional(seq('as', field('alias', $._name)))),

    use_group: $ => seq(
      '{',
      $.use_leaf,
      repeat(seq(',', $.use_leaf)),
      optional(','),
      '}',
    ),

    use_leaf: $ => seq($._name, optional(seq('as', field('alias', $._name)))),

    // -- interface / impl -------------------------------------------------
    interface_definition: $ => seq(
      optional($.visibility),
      'interface',
      field('name', $.identifier),
      optional($.type_parameters),
      '{',
      repeat($._interface_item),
      '}',
    ),

    _interface_item: $ => choice(
      $.interface_method,
      $.associated_type,
    ),

    // interface_method ::= "fn" IDENT type_params? "(" params? ")" ret? block?
    // The trailing block is a *default* body (plan-era interface defaults): an
    // impl that omits the method inherits it. A bare signature (no block) stays
    // an abstract requirement.
    interface_method: $ => seq(
      'fn',
      field('name', $.identifier),
      optional($.type_parameters),
      field('parameters', $.parameter_list),
      optional($.return_type),
      optional(field('body', $.block)),
    ),

    associated_type: $ => seq(
      'type',
      field('name', $.identifier),
      optional(seq('=', field('type', $._type))),
    ),

    impl_definition: $ => seq(
      'impl',
      field('interface', $.identifier),
      optional(seq('for', field('type', $.identifier))),
      '{',
      repeat($._impl_item),
      '}',
    ),

    _impl_item: $ => choice(
      $.impl_method,
      $.associated_type_binding,
    ),

    impl_method: $ => seq(
      optional($.visibility),
      optional('const'),
      'fn',
      field('name', $.identifier),
      optional($.type_parameters),
      field('parameters', $.parameter_list),
      optional($.return_type),
      field('body', $.block),
    ),

    associated_type_binding: $ => seq(
      'type',
      field('name', $.identifier),
      '=',
      field('type', $._type),
    ),

    // -- directives -------------------------------------------------------
    // `@include`, `@link`, `@link_macos`, etc. The argument is a parenthesized
    // or bare string / `<header>`.
    directive: $ => seq(
      '@',
      field('name', alias($.directive_name, $.identifier)),
      field('argument', $.directive_argument),
    ),

    directive_name: _ => choice(
      'include',
      'link',
      'link_macos',
      'link_linux',
      'link_windows',
    ),

    directive_argument: $ => choice(
      seq('(', choice($.string, $.include_path), ')'),
      $.string,
      $.include_path,
    ),

    // `<stdio.h>` style header path: anything up to the closing `>`.
    include_path: _ => token(seq('<', /[^>\n]*/, '>')),

    // -- types ------------------------------------------------------------
    _type: $ => choice(
      $.optional_type,
      $._postfix_type,
      $.function_type,
    ),

    // Types that may take the postfix optional shorthand. A function type's
    // return recursively consumes `?`; a pointer is itself postfixable, so
    // `*int?` means Optional<*int>, matching the production parser.
    _postfix_type: $ => choice(
      $.primitive_type,
      $.numeric_width_type,
      $.generic_type,
      $.named_type,
      $.array_type,
      $.dict_type,
      $.tuple_type,
      $.pointer_type,
    ),

    optional_type: $ => prec.left(PREC.postfix, seq(
      field('type', $._postfix_type),
      repeat1('?'),
    )),

    primitive_type: _ => choice('int', 'float', 'bool', 'string', 'void'),

    numeric_width_type: _ => choice(
      'i8', 'u8', 'i16', 'u16', 'i32', 'u32', 'i64', 'u64', 'f16', 'f32',
    ),

    named_type: $ => prec(PREC.primary, choice(
      $.identifier,
      'Error',
      'Range',
    )),

    generic_type: $ => seq(
      field('name', choice($.identifier, 'Future', 'Optional', 'Result')),
      $.type_arguments,
    ),

    type_arguments: $ => seq(
      '<',
      $._type,
      repeat(seq(',', $._type)),
      optional(','),
      '>',
    ),

    array_type: $ => seq('[', $._type, ']'),

    dict_type: $ => seq('{', field('key', $._type), ':', field('value', $._type), '}'),

    tuple_type: $ => seq(
      '(',
      optional(seq(
        $._type,
        repeat(seq(',', $._type)),
        optional(','),
      )),
      ')',
    ),

    function_type: $ => seq(
      'fn',
      '(',
      optional($._type_list),
      ')',
      '->',
      $._type,
    ),

    pointer_type: $ => seq('*', optional('mut'), choice($._postfix_type, $.function_type)),

    _type_list: $ => seq(
      $._type,
      repeat(seq(',', $._type)),
      optional(','),
    ),

    // -- blocks / statements ----------------------------------------------
    // block ::= "{" stmt* expr? "}"
    block: $ => seq(
      '{',
      repeat($._statement),
      optional(field('result', $._expression)),
      '}',
    ),

    _statement: $ => choice(
      $.let_statement,
      $.return_statement,
      $.while_statement,
      $.for_statement,
      $.break_statement,
      $.continue_statement,
      $.defer_statement,
      $.assignment_statement,
      $.expression_statement,
    ),

    // A let head accepts the complete pattern surface. Keep a lone identifier
    // as an `identifier` node for compatibility with definition queries; nested
    // identifiers remain ordinary `binding_pattern` nodes.
    let_statement: $ => seq(
      'let',
      optional('mut'),
      field('pattern', $._let_pattern),
      optional(seq(':', field('type', $._type))),
      '=',
      field('value', $._expression),
      optional(seq('else', field('alternative', $.block))),
      optional(';'),
    ),

    _let_pattern: $ => choice(
      $.identifier,
      $.wildcard_pattern,
      $.none_pattern,
      $.binding_subpattern,
      $.literal_pattern,
      $.range_pattern,
      $.string_prefix_pattern,
      $.string_suffix_pattern,
      $.string_contains_pattern,
      $.tuple_pattern,
      $.struct_pattern,
      $.enum_pattern,
      $.option_result_pattern,
      $.array_pattern,
    ),

    return_statement: $ => prec.right(seq(
      'return',
      optional(field('value', $._expression)),
      optional(';'),
    )),

    while_statement: $ => seq(
      optional(field('label', $.loop_label)),
      'while',
      field('condition', choice($._control_expression, $.conditional_let)),
      field('body', $.block),
    ),

    for_statement: $ => seq(
      optional(field('label', $.loop_label)),
      'for',
      field('pattern', $._pattern),
      'in',
      field('iterable', $._control_expression),
      field('body', $.block),
    ),

    // defer_stmt ::= "defer" statement — run when the enclosing block exits.
    defer_statement: $ => seq('defer', $._statement),

    loop_label: $ => seq(field('name', $.identifier), ':'),

    // Consume horizontal whitespace explicitly before an optional target. Using
    // immediate tokens here is deliberate: ordinary extras include newlines,
    // but `break\nname` and `continue\nname` are bare controls followed by a new
    // statement, matching Moon's parser and bare-return rule.
    _loop_control_label: $ => seq(
      token.immediate(/[ \t]+/),
      field('label', alias(token.immediate(/[a-zA-Z_][a-zA-Z0-9_]*/), $.identifier)),
    ),

    break_statement: $ => prec.right(seq('break', optional($._loop_control_label), optional(';'))),

    continue_statement: $ => prec.right(seq('continue', optional($._loop_control_label), optional(';'))),

    // assign_stmt ::= lvalue assign_op expr. The lvalue is parsed as a general
    // postfix expression in parser.zig, so accept any expression as target.
    assignment_statement: $ => prec.right(1, seq(
      field('target', $._expression),
      field('operator', choice('=', '+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=', '<<=', '>>=')),
      field('value', $._expression),
      optional(';'),
    )),

    expression_statement: $ => prec(-1, seq($._expression, optional(';'))),

    // Control-flow heads (`if`/`while`/`for`/`match` scrutinee) disallow a bare
    // struct literal at the OUTERMOST level so the following `{` reads as the
    // body's block. parser.zig models this by clearing `allow_struct_lit`, which
    // `enterGroup` restores once inside any delimiter (plan 123 bug 2 — until
    // that fix the compiler kept it cleared through nested groups and rejected
    // what this grammar already accepted). We mirror that exactly: a
    // control expression is any expression except one whose top node is a struct
    // literal; struct literals nested inside parens/calls/etc. remain legal
    // because those inner positions recurse back into the full `_expression`.
    _control_expression: $ => choice(
      $._literal,
      $.identifier,
      $.path_expression,
      $.generator_expression,
      $.parenthesized_expression,
      $.tuple_expression,
      $.array_comprehension,
      $.array_expression,
      $.dict_comprehension,
      $.dict_expression,
      $.closure_expression,
      $.block,
      $.if_expression,
      $.match_expression,
      $.unary_expression,
      $.binary_expression,
      $.range_expression,
      $.cast_expression,
      $.call_expression,
      $.turbofish_call_expression,
      $.index_expression,
      $.field_expression,
      $.tuple_index_expression,
      $.try_expression,
      $.await_expression,
      $.address_of_expression,
      $.dereference_expression,
      $.some_expression,
      $.none_expression,
      $.ok_expression,
      $.err_expression,
    ),

    // -- expressions ------------------------------------------------------
    _expression: $ => choice(
      $._literal,
      $.identifier,
      $.path_expression,
      $.generator_expression,
      $.parenthesized_expression,
      $.tuple_expression,
      $.array_comprehension,
      $.array_expression,
      $.dict_comprehension,
      $.dict_expression,
      $.struct_literal,
      $.closure_expression,
      $.block,
      $.if_expression,
      $.match_expression,
      $.unary_expression,
      $.binary_expression,
      $.range_expression,
      $.cast_expression,
      $.call_expression,
      $.turbofish_call_expression,
      $.index_expression,
      $.field_expression,
      $.tuple_index_expression,
      $.try_expression,
      $.await_expression,
      $.address_of_expression,
      $.dereference_expression,
      $.some_expression,
      $.none_expression,
      $.ok_expression,
      $.err_expression,
    ),

    _literal: $ => choice(
      $.integer_literal,
      $.float_literal,
      $.boolean_literal,
      $.string,
    ),

    // Dotted qualification and value member access are intentionally the same
    // syntactic shape; semantic resolution decides whether `a.b` names a module
    // item or a field. `path_expression` is retained only for leading enum
    // shorthand (`.Ready`).
    path_expression: $ => prec(PREC.primary, seq('.', $._name)),

    parenthesized_expression: $ => seq('(', $._expression, ')'),

    generator_expression: $ => seq(
      '(',
      field('value', $._expression),
      $.comprehension_for_clause,
      repeat(choice($.comprehension_for_clause, $.comprehension_if_clause)),
      ')',
    ),

    // tuple_lit ::= "(" ")" | "(" expr "," (expr ("," expr)* ","?)? ")"
    tuple_expression: $ => choice(
      seq('(', ')'),
      seq(
        '(',
        $._expression,
        ',',
        optional(seq(
          $._expression,
          repeat(seq(',', $._expression)),
          optional(','),
        )),
        ')',
      ),
    ),

    array_expression: $ => seq(
      '[',
      optional(seq(
        $._expression,
        repeat(seq(',', $._expression)),
        optional(','),
      )),
      ']',
    ),

    array_comprehension: $ => seq(
      '[',
      field('value', $._expression),
      $.comprehension_for_clause,
      repeat(choice($.comprehension_for_clause, $.comprehension_if_clause)),
      ']',
    ),

    comprehension_for_clause: $ => seq(
      'for',
      field('pattern', $._pattern),
      'in',
      field('iterable', $._expression),
    ),

    comprehension_if_clause: $ => seq(
      'if',
      field('condition', $._expression),
    ),

    dict_comprehension: $ => seq(
      '{',
      field('key', $._expression),
      ':',
      field('value', $._expression),
      $.comprehension_for_clause,
      repeat(choice($.comprehension_for_clause, $.comprehension_if_clause)),
      '}',
    ),

    // dict_lit ::= "{:" "}" | "{" dict_entry ("," dict_entry)* ","? "}"
    // The lexer emits `{` `:` `}` separately, so spell the empty form out.
    dict_expression: $ => choice(
      seq('{', ':', '}'),
      seq(
        '{',
        $.dict_entry,
        repeat(seq(',', $.dict_entry)),
        optional(','),
        '}',
      ),
    ),

    dict_entry: $ => seq(field('key', $._expression), ':', field('value', $._expression)),

    closure_expression: $ => prec.right(seq(
      field('parameters', choice(
        $.closure_parameters,
        alias('||', $.closure_parameters),
      )),
      optional($.return_type),
      field('body', $._expression),
    )),

    closure_parameters: $ => seq(
      '|',
      optional(seq(
        $.closure_parameter,
        repeat(seq(',', $.closure_parameter)),
        optional(','),
      )),
      '|',
    ),

    closure_parameter: $ => seq(
      field('name', $.identifier),
      optional(seq(':', field('type', $._type))),
    ),

    if_expression: $ => prec.right(seq(
      'if',
      field('condition', choice($._control_expression, $.conditional_let)),
      field('consequence', $.block),
      optional(seq('else', field('alternative', choice($.if_expression, $.block)))),
    )),

    conditional_let: $ => seq(
      'let',
      field('pattern', $._pattern),
      '=',
      field('value', $._control_expression),
    ),

    // parser.zig separates arms with an OPTIONAL comma: after each arm body it
    // does `if (!match(comma)) { skipSeparators(); if r_brace break; }`. So a
    // trailing comma is optional and block-bodied arms are commonly written
    // without one (`some(v) => { ... } none => { ... }`). The comma is folded
    // into the arm as an optional suffix and arms repeat freely.
    match_expression: $ => seq(
      'match',
      field('value', $._control_expression),
      '{',
      repeat($.match_arm),
      '}',
    ),

    // The arm body is any expression — including a `block` (`=> { ... }`) — or a
    // bare `return`. `$.block` already lives in `$._expression`.
    match_arm: $ => seq(
      field('pattern', $._pattern),
      repeat(seq('|', field('pattern', $._pattern))),
      optional(seq('if', field('guard', $._expression))),
      '=>',
      field('value', choice($._expression, $.return_statement)),
      optional(','),
    ),

    // parser.zig gives address-of and dereference dedicated AST nodes (rather
    // than generic unary operators), so `&`/`*` live in their own rules.
    unary_expression: $ => prec(PREC.unary, seq(
      field('operator', choice('-', '!')),
      field('operand', $._expression),
    )),

    address_of_expression: $ => prec(PREC.unary, seq('&', field('operand', $._expression))),

    dereference_expression: $ => prec(PREC.unary, seq('*', field('operand', $._expression))),

    await_expression: $ => prec(PREC.unary, seq('await', field('operand', $._expression))),

    // Every binary operator is left-associative. Precedences come straight from
    // parser.zig `binPrec`.
    binary_expression: $ => {
      const table = [
        [PREC.or, '||'],
        [PREC.and, '&&'],
        [PREC.equality, '=='],
        [PREC.equality, '!='],
        [PREC.equality, '|'],
        [PREC.bitand, '&'],
        [PREC.bitand, '^'],
        [PREC.compare, '<'],
        [PREC.compare, '<='],
        [PREC.compare, '>'],
        [PREC.compare, '>='],
        [PREC.compare, '<<'],
        [PREC.compare, '>>'],
        [PREC.additive, '+'],
        [PREC.additive, '-'],
        [PREC.multiplicative, '*'],
        [PREC.multiplicative, '/'],
        [PREC.multiplicative, '%'],
      ];
      return choice(...table.map(([precedence, operator]) =>
        prec.left(precedence, seq(
          field('left', $._expression),
          field('operator', operator),
          field('right', $._expression),
        ))));
    },

    // range_expr ::= additive (".." additive)?  — at comparison precedence (5)
    // in the ladder, and non-associative (at most one `..`).
    range_expression: $ => prec.left(PREC.compare, seq(
      field('start', $._expression),
      '..',
      field('end', $._expression),
    )),

    cast_expression: $ => prec.left(PREC.cast, seq(
      field('value', $._expression),
      'as',
      field('type', $._type),
    )),

    // -- postfix forms ----------------------------------------------------
    call_expression: $ => prec(PREC.postfix, seq(
      field('function', $._expression),
      field('arguments', $.arguments),
    )),

    // A bare `<` after the callee opens an explicit type-argument list only
    // when it closes on a `>` immediately before `(`; anywhere else the same
    // token is the comparison operator. Both readings share a prefix, so the
    // conflict is declared above and GLR carries the two stacks until the `(`
    // decides. Where both readings still complete (`a < b > (c)`), the positive
    // dynamic precedence selects the call — the same choice parser.zig's
    // `looksLikeTypeArgs` makes.
    turbofish_call_expression: $ => prec.dynamic(1, prec(PREC.postfix, seq(
      field('function', $._expression),
      field('type_arguments', $.turbofish),
      field('arguments', $.arguments),
    ))),

    turbofish: $ => seq(
      '<',
      $._type,
      repeat(seq(',', $._type)),
      optional(','),
      '>',
    ),

    arguments: $ => seq(
      '(',
      optional(seq(
        $._argument,
        repeat(seq(',', $._argument)),
        optional(','),
      )),
      ')',
    ),

    // A `name:` prefix marks a named argument (plan 09) — mirrors parser.zig's
    // two-token `ident ':'` lookahead in finishCall. Positional arguments stay
    // bare expressions so existing consumers/queries are unaffected.
    _argument: $ => choice($.named_argument, $._expression),

    named_argument: $ => seq(field('name', $.identifier), ':', $._expression),

    index_expression: $ => prec(PREC.postfix, seq(
      field('object', $._expression),
      '[',
      field('index', $._expression),
      ']',
    )),

    // `.` method_ident — may be followed by call args (handled by call_expression
    // wrapping a field_expression). `let` and the result/option constructor
    // keywords (`ok`/`err`/`some`/`none`) are valid field/method names.
    field_expression: $ => prec(PREC.postfix, seq(
      field('object', $._expression),
      '.',
      field('field', choice(
        $.identifier,
        alias('let', $.identifier),
        alias('ok', $.identifier),
        alias('err', $.identifier),
        alias('some', $.identifier),
        alias('none', $.identifier),
      )),
    )),

    // `.0`, `.1` tuple-index access. The lexer hands us an int literal here.
    tuple_index_expression: $ => prec(PREC.postfix, seq(
      field('object', $._expression),
      '.',
      field('index', $.integer_literal),
    )),

    try_expression: $ => prec(PREC.postfix, seq($._expression, '?')),

    // some/none/ok/err constructors.
    some_expression: $ => prec(PREC.primary, seq('some', '(', $._expression, ')')),
    none_expression: _ => prec(PREC.primary, 'none'),
    ok_expression: $ => prec(PREC.primary, seq('ok', '(', $._expression, ')')),
    // err ::= "err" "." IDENT ("(" expr ")")?
    err_expression: $ => prec.right(PREC.primary, seq(
      'err',
      '.',
      field('name', $.identifier),
      optional(seq('(', field('message', $._expression), ')')),
    )),

    // struct_lit ::= IDENT "{" struct_lit_item_list? "}"
    // Negative dynamic precedence: when a struct-literal reading competes with a
    // control-flow condition reading (`if x {`, `match x {`, ...), the condition
    // wins. In ordinary positions (`let c = C { ... }`) no such competitor
    // exists, so the struct literal is still chosen.
    struct_literal: $ => prec.dynamic(-1, seq(
      field('name', $.identifier),
      field('body', $.struct_literal_body),
    )),

    struct_literal_body: $ => seq(
      '{',
      optional(seq(
        $._struct_literal_item,
        repeat(seq(',', $._struct_literal_item)),
        optional(','),
      )),
      '}',
    ),

    _struct_literal_item: $ => choice(
      $.struct_literal_field,
      $.struct_spread,
    ),

    struct_literal_field: $ => seq(
      field('name', $.identifier),
      optional(seq(':', field('value', $._expression))),
    ),

    struct_spread: $ => seq('...', $._expression),

    // -- patterns ---------------------------------------------------------
    _pattern: $ => choice(
      $.wildcard_pattern,
      $.none_pattern,
      $.binding_pattern,
      $.binding_subpattern,
      $.literal_pattern,
      $.range_pattern,
      $.string_prefix_pattern,
      $.string_suffix_pattern,
      $.string_contains_pattern,
      $.tuple_pattern,
      $.struct_pattern,
      $.enum_pattern,
      $.option_result_pattern,
      $.array_pattern,
    ),

    wildcard_pattern: _ => '_',

    none_pattern: _ => 'none',

    binding_pattern: $ => $.identifier,

    // name @ pattern
    binding_subpattern: $ => seq(field('name', $.identifier), '@', field('pattern', $._pattern)),

    literal_pattern: $ => choice(
      $.integer_literal,
      seq('-', $.integer_literal),
      $.boolean_literal,
      $.string,
    ),

    // range_pattern ::= ("-"? INT) (".." | "..=") ("-"? INT)
    range_pattern: $ => seq(
      field('start', seq(optional('-'), $.integer_literal)),
      choice('..', '..='),
      field('end', seq(optional('-'), $.integer_literal)),
    ),

    // String wildcard patterns:  "a"..   .."b"   .."c"..
    string_prefix_pattern: $ => prec(1, seq($.string, '..')),
    string_suffix_pattern: $ => prec(1, seq('..', $.string)),
    string_contains_pattern: $ => prec(2, seq('..', $.string, '..')),

    tuple_pattern: $ => seq(
      '(',
      optional(seq(
        $._pattern,
        repeat(seq(',', $._pattern)),
        optional(','),
      )),
      ')',
    ),

    // IDENT "{" field_pattern_list? "}"
    struct_pattern: $ => seq(
      field('name', $.identifier),
      '{',
      optional(seq(
        choice($.field_pattern, $.rest_pattern),
        repeat(seq(',', choice($.field_pattern, $.rest_pattern))),
        optional(','),
      )),
      '}',
    ),

    field_pattern: $ => seq(
      field('name', $.identifier),
      optional(seq(':', field('pattern', $._pattern))),
    ),

    rest_pattern: _ => choice('...', '..'),

    // IDENT "(" pattern_list? ")"  |  IDENT "." IDENT (...)?  |  "." IDENT (...)?
    enum_pattern: $ => choice(
      seq(
        field('enum', $.identifier),
        '.',
        field('variant', $.identifier),
        optional($.pattern_arguments),
      ),
      seq('.', field('variant', $.identifier), optional($.pattern_arguments)),
      seq(field('variant', $.identifier), $.pattern_arguments),
    ),

    // some(p)/ok(p)/err(p) and bare some/ok/err in pattern position.
    option_result_pattern: $ => seq(
      field('variant', choice('some', 'ok', 'err')),
      optional($.pattern_arguments),
    ),

    pattern_arguments: $ => seq(
      '(',
      optional(seq(
        $._pattern,
        repeat(seq(',', $._pattern)),
        optional(','),
      )),
      ')',
    ),

    // array_pattern ::= "[" (pat ("," pat)* ("," ".." pat?)?)? "]"  |  ".." pat?
    array_pattern: $ => seq(
      '[',
      optional(seq(
        repeat(seq($._pattern, ',')),
        choice(
          seq($._pattern, optional(',')),
          seq($.rest_element, optional(seq(',', $._pattern, repeat(seq(',', $._pattern)), optional(',')))),
        ),
      )),
      ']',
    ),

    rest_element: $ => seq(choice('...', '..'), optional($._pattern)),

    // -- lexical / terminals ----------------------------------------------
    // A name is an identifier or a primitive-type keyword used as a path
    // segment (`std.string`), matching parser.zig `isNameTag`.
    _name: $ => choice($.identifier, 'int', 'float', 'bool', 'string', 'void'),

    // STRING with `$IDENT` and `${ expr }` interpolation. The scanner-free
    // approximation: a string is a run of normal chars, escapes, and
    // interpolations between double quotes. Injections re-parse the `${...}`
    // bodies as Moon via queries/injections.scm.
    string: $ => seq(
      '"',
      repeat(choice(
        $.string_content,
        $.escape_sequence,
        $.interpolation,
        $.dollar,
      )),
      token.immediate('"'),
    ),

    string_content: _ => token.immediate(prec(1, /[^"\\$\n]+/)),

    // interpreter.zig decodes `\` + one char: `n`/`t`/`r`/`"`/`$`/`\` are the
    // named escapes, and *any other* following char is passed through literally
    // (`else => s[i]`). So the token is a backslash plus any single non-newline
    // character — `\u`, `\r`, `\0`, ... all lex as an escape rather than erroring.
    escape_sequence: _ => token.immediate(/\\[^\n]/),

    // `${ expr }` re-parses `expr` as Moon (see injections.scm). `$name` is the
    // short form; it is a SINGLE immediate token so the lexer's longest-match
    // always prefers it (and `${`) over a bare literal `$`, avoiding any parse
    // ambiguity. A `$` that begins neither form is the literal `$` node below.
    interpolation: $ => choice(
      seq(token.immediate('${'), $._expression, '}'),
      alias(token.immediate(/\$[a-zA-Z_][a-zA-Z0-9_]*/), $.interpolation_variable),
    ),

    // A literal `$` inside a string — one that is not followed by `{` or an
    // identifier, e.g. the `$2`/`$1` backreferences in a regex replacement
    // string. interpreter.zig's `interpolate` leaves such a `$` verbatim.
    dollar: _ => token.immediate('$'),

    // Decimal with `_` digit separators, or 0x/0b/0o radix-prefixed.
    integer_literal: _ => token(choice(
      /[0-9](_?[0-9])*/,
      /0x[0-9a-fA-F](_?[0-9a-fA-F])*/,
      /0b[01](_?[01])*/,
      /0o[0-7](_?[0-7])*/,
    )),

    // FLOAT_LIT requires a digit on BOTH sides of the dot (lexer.zig): `5.` and
    // `t.0.0` are NOT floats. The regex enforces digit-dot-digit. An `e`/`E`
    // exponent (optionally signed) makes a literal a float even without a
    // fractional part.
    float_literal: _ => token(choice(
      /[0-9](_?[0-9])*\.[0-9](_?[0-9])*([eE][+-]?[0-9](_?[0-9])*)?/,
      /[0-9](_?[0-9])*[eE][+-]?[0-9](_?[0-9])*/,
    )),

    boolean_literal: _ => choice('true', 'false'),

    line_comment: _ => token(seq('//', /[^\n]*/)),

    // block_comment is supplied by the external scanner (see `externals` above
    // and src/scanner.c). It handles arbitrarily nested `/* /* */ */` pairs,
    // matching lexer.zig's `skipBlockComment`.

    identifier: _ => /[a-zA-Z_][a-zA-Z0-9_]*/,
  },
});
