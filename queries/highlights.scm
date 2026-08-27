; Syntax highlighting for Moon.
; Capture names follow the tree-sitter / nvim-treesitter highlight conventions
; (the taxonomy the official Rust and Go queries use), so a theme lights Moon up
; with the full spread of colors: keywords split by role, namespaces, builtin
; functions, `self`, constructors, and definition sites each get their own group.
;
; ORDERING: nvim-treesitter resolves overlapping captures "last wins" — a later
; pattern overrides an earlier one on the same node. So the generic
; `(identifier) @variable` baseline comes FIRST and every specific identifier
; rule follows it (exactly as tree-sitter-rust's query is laid out). Rules are
; ordered general -> specific; the intended winner for any node is the last rule
; that matches it.

; -- baseline ---------------------------------------------------------------
; Everything that is a bare identifier starts as a variable; the rules below
; refine each occurrence to its real role.
(identifier) @variable

; -- comments ---------------------------------------------------------------
(line_comment) @comment @spell
(block_comment) @comment @spell

; -- literals ---------------------------------------------------------------
(integer_literal) @number
(float_literal) @number.float
(boolean_literal) @boolean

(string) @string
(escape_sequence) @string.escape
; The `${` ... `}` punctuation around a braced interpolation, and the `$name`
; short form (a single token that includes its `$` sigil).
(interpolation "${" @punctuation.special)
(interpolation "}" @punctuation.special)
(interpolation_variable) @variable

; -- keywords ---------------------------------------------------------------
; Declaration keywords, split by role so a theme can tint types, functions, and
; imports differently (as the Rust/Go queries do).
"fn" @keyword.function

[
  "type"
  "struct"
  "enum"
  "interface"
  "impl"
] @keyword.type

"use" @keyword.import

[
  "let"
  "defer"
] @keyword

; Modifiers that decorate a declaration rather than introduce one.
(visibility) @keyword.modifier
[
  "const"
  "mut"
  "extern"
] @keyword.modifier

[
  "if"
  "else"
  "match"
] @keyword.conditional

[
  "while"
  "for"
  "in"
  "break"
  "continue"
] @keyword.repeat

[
  "return"
] @keyword.return

[
  "async"
  "await"
] @keyword.coroutine

; `as` is the cast operator everywhere except an import rename; the import form
; is listed last so it wins there.
"as" @keyword.operator
(use_single "as" @keyword.import)
(use_leaf "as" @keyword.import)

[
  "some"
  "none"
  "ok"
  "err"
] @constant.builtin

; -- types ------------------------------------------------------------------
(primitive_type) @type.builtin
(numeric_width_type) @type.builtin
(named_type ["Error" "Range"] @type.builtin)

; Any PascalCase identifier in value or type position reads as a type by default.
((identifier) @type
  (#match? @type "^[A-Z]"))

(named_type (identifier) @type)
(generic_type name: (identifier) @type)
(generic_type name: (_) @type.builtin
  (#any-of? @type.builtin "Future" "Optional" "Result"))
; Interface bounds on a type parameter (`<T: Weight + Show>`) name types.
(type_parameter bound: (identifier) @type)
(impl_definition (identifier) @type)

; Definition sites get @type.definition; use sites stay @type. Themes that don't
; distinguish the two fall back to @type, so this only adds color where wanted.
(struct_definition name: (identifier) @type.definition)
(enum_definition name: (identifier) @type.definition)
(interface_definition name: (identifier) @type.definition)
(type_alias name: (identifier) @type.definition)

; Loop labels form their own control-flow namespace.
(loop_label name: (identifier) @label)
(break_statement label: (identifier) @label)
(continue_statement label: (identifier) @label)

; Constructors: enum variants (definition, value, and pattern positions),
; struct-literal heads, and `err.Variant`.
(variant name: (identifier) @constructor)
(struct_literal name: (identifier) @constructor)
(err_expression name: (identifier) @constructor)
(enum_pattern variant: (identifier) @constructor)

; -- modules / namespaces ---------------------------------------------------
; Qualifier segments of a path get the module color (lowercase only, so a
; PascalCase `Color.Red` head still reads as a type). The call rules below run
; afterwards, so the final segment of `std.mem.swap(...)` still reads as a call.
((use_path (identifier) @module)
  (#match? @module "^[a-z_]"))
((path_expression (identifier) @module)
  (#match? @module "^[a-z_]"))

; -- fields / members -------------------------------------------------------
(field_declaration name: (identifier) @variable.member)
(field_expression field: (identifier) @variable.member)
(struct_literal_field name: (identifier) @variable.member)
(field_pattern name: (identifier) @variable.member)
(dict_entry key: (_) @variable.member)

; -- parameters -------------------------------------------------------------
(parameter name: (identifier) @variable.parameter)
(closure_parameter name: (identifier) @variable.parameter)
(named_argument name: (identifier) @variable.parameter)

; `self` is a plain identifier in the grammar but reads as the method receiver.
; Listed after the parameter rule so it wins in the `self: Vec` position too.
((identifier) @variable.builtin
  (#eq? @variable.builtin "self"))

; -- functions --------------------------------------------------------------
(function_definition name: (identifier) @function)
(extern_function name: (identifier) @function)
(interface_method name: (identifier) @function.method)
(impl_method name: (identifier) @function.method)

; Call targets. The path form's `.` anchor picks the final segment, overriding
; the @module rule above for `pkg.fn(...)`.
(call_expression
  function: (identifier) @function.call)
(call_expression
  function: (path_expression (identifier) @function.call .))
(turbofish_call_expression
  function: (identifier) @function.call)
; A `recv.method(...)` call — overrides the @variable.member field rule above.
(call_expression
  function: (field_expression field: (identifier) @function.method.call))

; Reserved builtin free functions (`print`/`println`/`to_string` and the async
; runtime builtins). Overrides the generic @function.call for these names.
((call_expression
  function: (identifier) @function.builtin)
  (#any-of? @function.builtin
    "print" "println" "to_string"
    "run" "sleep" "spawn" "join_all" "select" "cancel" "is_cancelled"))

; -- directives / attributes ------------------------------------------------
(directive "@" @attribute) @attribute
(directive name: (identifier) @attribute)
(struct_attribute) @attribute
(include_path) @string.special.path

; -- punctuation ------------------------------------------------------------
[
  "("
  ")"
  "["
  "]"
  "{"
  "}"
] @punctuation.bracket

(turbofish "<" @punctuation.bracket ">" @punctuation.bracket)
(type_arguments "<" @punctuation.bracket ">" @punctuation.bracket)
(type_parameters "<" @punctuation.bracket ">" @punctuation.bracket)

[
  ","
  ":"
  ";"
  "."
  "->"
  "=>"
] @punctuation.delimiter

; -- operators --------------------------------------------------------------
; Keep pointer syntax explicit as well as covered by the generic operator list:
; this pins all three contexts when editors consume only named-node patterns.
(address_of_expression "&" @operator)
(dereference_expression "*" @operator)
(pointer_type "*" @operator)

[
  "+"
  "-"
  "*"
  "/"
  "%"
  "=="
  "!="
  "<"
  "<="
  ">"
  ">="
  "<<"
  ">>"
  "&"
  "|"
  "^"
  "&&"
  "||"
  "!"
  "="
  "+="
  "-="
  "*="
  "/="
  "%="
  "&="
  "|="
  "^="
  "<<="
  ">>="
  ".."
  "..="
  "..."
  "?"
  "@"
] @operator
