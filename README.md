# tree-sitter-moon

A [tree-sitter](https://tree-sitter.github.io/tree-sitter/) grammar for the
**Moon** language.

It powers editor features that need a real syntax tree — semantic syntax
highlighting, structural selection, code folding, indentation, symbol outlines,
and language injection inside string interpolations.

## Relationship to the compiler

This grammar is a faithful transcription of the Moon front-end that lives in the
parent repository. Keep it in sync with these files:

| Grammar concern        | Source of truth                |
| ---------------------- | ------------------------------ |
| Token / keyword set    | `../src/frontend/token.zig` (`Tag` enum, `keywordTag`) |
| Lexical rules          | `../src/frontend/lexer.zig`             |
| Items, expressions, patterns, operator precedence | `../src/frontend/parser.zig` |
| Canonical EBNF         | `../moon.md`, `## Formal Grammar` |

**Drift guard:** the set of terminal tokens in `grammar.js` must match
`src/frontend/token.zig`'s `Tag`. When the compiler adds or renames a keyword/operator,
update the lexical rules here in the same change, regenerate, and re-run the
corpus tests.

The operator precedence ladder mirrors `parser.zig`'s `binPrec` exactly,
including two Moon-specific quirks that differ from most C-family languages:

- `|` (bitwise or) sits at the **equality** precedence level, alongside `==`/`!=`.
- `..` (range) sits at the **comparison** level.

All binary operators are left-associative.

## Building and testing

The [`tree-sitter` CLI](https://github.com/tree-sitter/tree-sitter) drives
everything.

```sh
# Regenerate src/parser.c from grammar.js (run after every grammar edit).
tree-sitter generate

# Run the corpus tests in test/corpus/ (parse tree assertions).
tree-sitter test

# Compile the parser into a loadable library to sanity-check the C output.
tree-sitter build           # native (creates moon.so / moon.dylib / moon.dll)
tree-sitter build --wasm    # WebAssembly, for the web playground

# Parse a file and print its syntax tree.
tree-sitter parse ../examples/19_pattern_matching.mn

# Validate a query against a source file.
tree-sitter query queries/highlights.scm ../examples/05_functions.mn

# Interactive browser playground (needs a prior `tree-sitter build --wasm`).
tree-sitter playground
```

The corpus under `test/corpus/` was generated from the grammar itself and is
verified by `tree-sitter test`; every example in `../examples/*.mn` parses
without an `ERROR` or `MISSING` node.

## Queries

| File                       | Purpose                                                        |
| -------------------------- | -------------------------------------------------------------- |
| `queries/highlights.scm`   | Keywords, builtin and user types, functions, operators, punctuation, strings, numbers, booleans, comments, directives. |
| `queries/locals.scm`       | Scopes (fn / block / closure / loop / match arm), definitions (params, `let`, `for`, pattern bindings), and references. |
| `queries/injections.scm`   | Injects `moon` into `${ ... }` string interpolations, and `comment` into `//` line comments. |

## How editors consume it

- **Neovim** (`nvim-treesitter`): register a parser pointing at this directory
  (`require('nvim-treesitter.parsers')`), then copy `queries/` into
  `queries/moon/` on your runtime path. `.mn` files map to the `moon`
  filetype.
- **Helix**: add a `[[language]]` entry with `name = "moon"` and a
  `[[grammar]]` source pointing at this repo, run `hx --grammar fetch && hx
  --grammar build`, then place the `.scm` files under
  `runtime/queries/moon/`.
- **Emacs** (`moon-ts-mode` / generic `treesit`): build the shared object with
  `tree-sitter build` and load it via `treesit-language-source-alist`.
- **Editors using the Node binding** (`bindings/node`) or the **Rust crate**
  (`bindings/rust`, exposed as the `tree-sitter-moon` crate with the `LANGUAGE`
  constant and the `HIGHLIGHTS_QUERY` / `LOCALS_QUERY` / `INJECTIONS_QUERY`
  query strings) can embed the parser directly.

## Layout

```
grammar.js              the grammar (the single source you edit)
tree-sitter.json        grammar metadata + query paths (ABI 15)
queries/                highlights / locals / injections
test/corpus/            parse-tree assertions for `tree-sitter test`
bindings/node/          Node.js (N-API) binding
bindings/rust/          Rust binding + crate entry point
binding.gyp, Cargo.toml build manifests for the above
src/                    generated parser (parser.c, node-types.json, ...)
```

## Known limitations and resolved ambiguities

The grammar is GLR, so a few genuine ambiguities are resolved with declared
conflicts and precedence rather than extra lookahead:

- **Struct literal vs. control-flow body.** `Name { ... }` is a struct literal
  in value position but `Name` followed by a block after `if` / `while` / `for`
  / `match`. The compiler clears an `allow_struct_lit` flag in control
  positions; here, control conditions use a `_control_expression` rule that
  omits struct literals at the top level, and `struct_literal` carries a
  negative dynamic precedence so the condition-plus-block reading wins. A struct
  literal nested inside parentheses/calls within a condition still parses,
  matching the compiler (the flag is restored inside delimiters).
- **Turbofish vs. comparison.** `foo<T>(..)` and `foo < T` begin the same way,
  and only the `(` after the closing `>` separates them. The conflict is
  declared so GLR carries both stacks that far; where both readings still
  complete (`a < b > (c)`) a positive dynamic precedence on
  `turbofish_call_expression` picks the call, matching `looksLikeTypeArgs` in
  `parser.zig`. Every prefix operator on the callee (`*p<T>()` vs `*p < q`)
  needs the same conflict, hence the `unary`/`dereference`/`await`/`address_of`
  triples. The transitional `.<` opener was lexed as a single token so it never
  competed with a `. name` path segment; it has been removed, and `<` is the
  only opener.
- **Path length.** Path expressions are written with left recursion so they
  greedily absorb every `. name` segment (`a.b.c.d`) instead of truncating
  at the first interior `.`.
- **`>>` / `<<` vs. nested generics.** Type argument lists use `<` ... `>`. A
  `>>` that closes two nested generic lists is handled by the surrounding
  grammar context rather than a custom token split; the compiler does the
  equivalent by emitting a virtual `>` when it sees `>>` inside type args.
- **String interpolation** is approximated without an external scanner: a string
  is a run of content, escapes, and `${ expr }` / `$name` interpolations between
  quotes. This is faithful for well-formed strings; a stray unescaped `$` is
  treated as ordinary content. The `${ ... }` bodies are re-parsed as Moon via
  the injection query.
- **`..=` is pattern-only.** Inclusive ranges appear in patterns
  (`1..=5`); range *expressions* use `..` only, mirroring `parser.zig`'s
  `range_expr`.

## License

MIT
