# tree-sitter-moon

A [Tree-sitter](https://tree-sitter.github.io/tree-sitter/) grammar for the
Moon language. It powers the tour's static source blocks, Neovim, Zed, and
other clients that need an incremental syntax tree.

## Generated from Monogram

`grammar.js`, `queries/highlights.scm`, `src/parser.c`, `src/grammar.json`, and
`src/node-types.json` are generated from
[`../monogram/moon.ts`](../monogram/moon.ts). That executable Monogram grammar
also generates the TextMate grammars used by VS Code and Sublime Text and the
Monarch tokenizer used by the tour's live Monaco editor.

Do not edit those generated files directly. Bun is the package manager and
TypeScript runner for the source grammar:

```sh
cd editors/monogram
bun install --frozen-lockfile
bun run generate
bun run check
```

The check runs Monogram's executable parser against the repository's valid
Moon sources, requires an exact allowlist for its context-sensitive
token-stream limitations, parses every source with this generated GLR target,
runs the Tree-sitter corpus, and rejects artifact drift.

A few Moon rules need target-specific adaptations after Monogram generation:

- the external scanner balances nested `/* ... */` comments, which a regular
  token cannot express;
- a hidden physical-newline token preserves Moon's depth-zero expression
  statement boundary while allowing wrapped expressions inside delimiters;
- `$name` interpolation remains a structural token alongside `${ ... }`;
- GLR conflicts and dynamic precedence preserve Moon's contextual distinction
  between control-flow bodies and struct literals.

Both adaptations live in `../monogram/generate.ts` and are generated along
with the parser.

## Compiler relationship

Keep `../monogram/moon.ts` aligned with these language sources:

| Grammar concern | Compiler source of truth |
| --- | --- |
| Tokens and contextual keywords | `../../src/frontend/token.zig` |
| Lexical rules | `../../src/frontend/lexer.zig` |
| Items, expressions, patterns, and precedence | `../../src/frontend/parser.zig` |
| Canonical language grammar | `../../moon.md`, **Formal Grammar** |

Moon's `|` operator shares equality precedence with `==` and `!=`; `..`
shares comparison precedence. The generated grammar retains those rules.

## Direct Tree-sitter commands

The Bun install under `../monogram` pins the CLI used to generate this package:

```sh
../monogram/node_modules/.bin/tree-sitter test
../monogram/node_modules/.bin/tree-sitter build
../monogram/node_modules/.bin/tree-sitter build --wasm
../monogram/node_modules/.bin/tree-sitter parse ../../examples/hello.mn
```

The checked corpus under `test/corpus/` covers valid syntax, recovery, nested
comments, interpolation, declarations, expressions, patterns, and statements.

## Queries

| File | Purpose |
| --- | --- |
| `queries/highlights.scm` | Generated semantic captures for keywords, types, functions, properties, literals, punctuation, and comments. |
| `queries/locals.scm` | Scopes, bindings, declarations, labels, and identifier references. |
| `queries/injections.scm` | Moon in `${ ... }` substitutions and comment text in line comments. |

## Consumers

- Neovim and Helix can build the parser and install the three queries under
  their `moon` runtime query directory.
- Zed fetches the immutable `tree-sitter-moon-v0.2.0` public mirror tag.
- Node, Rust, Go, Python, Swift, and C consumers can use the generated bindings
  and metadata shipped by this package.

## Layout

```text
grammar.js              generated grammar
tree-sitter.json        grammar metadata and query paths (ABI 15)
queries/                generated highlights plus maintained locals/injections
test/corpus/            checked parse-tree assertions
bindings/               language bindings
src/                    generated parser and nested-comment/newline scanner
```

## License

MIT
