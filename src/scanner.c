// External scanner for Moon's NESTING block comments.
//
// Moon's lexer (src/lexer.zig `skipBlockComment`) allows `/* */` pairs to nest
// to any depth: `/* outer /* inner */ still outer */`. A tree-sitter regex
// token cannot balance the pairs, so the single `block_comment` external token
// declared in grammar.js is produced here instead.
//
// The scanner is intentionally stateless — a block comment is scanned in one
// call — so serialize/deserialize are no-ops.

#include "tree_sitter/parser.h"

enum TokenType {
  BLOCK_COMMENT,
};

void *tree_sitter_moon_external_scanner_create(void) { return NULL; }
void tree_sitter_moon_external_scanner_destroy(void *payload) { (void)payload; }

unsigned tree_sitter_moon_external_scanner_serialize(void *payload, char *buffer) {
  (void)payload;
  (void)buffer;
  return 0;
}

void tree_sitter_moon_external_scanner_deserialize(void *payload, const char *buffer,
                                                   unsigned length) {
  (void)payload;
  (void)buffer;
  (void)length;
}

static void advance(TSLexer *lexer) { lexer->advance(lexer, false); }
static void skip(TSLexer *lexer) { lexer->advance(lexer, true); }

bool tree_sitter_moon_external_scanner_scan(void *payload, TSLexer *lexer,
                                            const bool *valid_symbols) {
  (void)payload;
  if (!valid_symbols[BLOCK_COMMENT]) return false;

  // Leading whitespace is handled by the `/\s/` extra, but the scanner may be
  // invoked with some still pending; skip it without making it part of the
  // token so a following `/*` is recognised.
  while (lexer->lookahead == ' ' || lexer->lookahead == '\t' ||
         lexer->lookahead == '\n' || lexer->lookahead == '\r') {
    skip(lexer);
  }

  if (lexer->lookahead != '/') return false;
  advance(lexer);
  if (lexer->lookahead != '*') return false;
  advance(lexer);

  // We are inside the outermost `/* ... `; track nesting depth.
  unsigned depth = 1;
  for (;;) {
    switch (lexer->lookahead) {
      case '\0':
        // EOF before the comment closed: unterminated. Let the normal grammar
        // report the error rather than claiming a token.
        return false;
      case '/':
        advance(lexer);
        if (lexer->lookahead == '*') {
          advance(lexer);
          depth++;
        }
        break;
      case '*':
        advance(lexer);
        if (lexer->lookahead == '/') {
          advance(lexer);
          if (--depth == 0) {
            lexer->result_symbol = BLOCK_COMMENT;
            lexer->mark_end(lexer);
            return true;
          }
        }
        break;
      default:
        advance(lexer);
        break;
    }
  }
}
