; Language injections for Moon.

; Re-parse the expression inside each `${ ... }` string interpolation as Moon,
; so editors highlight interpolated code with the full grammar. Match the braced
; form specifically (the `"${"` delimiter): the `$name` short form is a single
; `interpolation_variable` token with no delimited expression to inject.
((interpolation
  "${"
  (_) @injection.content)
  (#set! injection.language "moon"))

; Highlight `// ...` comment bodies as plain text (lets editors apply
; comment-specific features like TODO/FIXME tagging via a `comment` injection).
((line_comment) @injection.content
  (#set! injection.language "comment"))
