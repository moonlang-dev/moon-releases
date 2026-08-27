; Local scopes, definitions, and references for Moon.
; Consumed by editors that resolve go-to-definition / rename and by
; nvim-treesitter's locals module.

; -- scopes -----------------------------------------------------------------
(function_definition) @local.scope
(extern_function) @local.scope
(interface_method) @local.scope
(impl_method) @local.scope
(closure_expression) @local.scope
(block) @local.scope
(for_statement) @local.scope
(array_comprehension) @local.scope
(dict_comprehension) @local.scope
(generator_expression) @local.scope
(while_statement) @local.scope
(if_expression) @local.scope
(match_expression) @local.scope
(match_arm) @local.scope

; -- definitions ------------------------------------------------------------
; Function/closure parameters.
(parameter name: (identifier) @local.definition.parameter)
(closure_parameter name: (identifier) @local.definition.parameter)

; `let` bindings: plain name and destructured names.
(let_statement pattern: (identifier) @local.definition.var)
(let_statement
  pattern: (tuple_pattern (binding_pattern (identifier) @local.definition.var)))
(let_statement
  pattern: (array_pattern (binding_pattern (identifier) @local.definition.var)))
(let_statement
  pattern: (struct_pattern (field_pattern name: (identifier) @local.definition.var)))

; Pattern bindings introduced inside a `match` arm.
; The same nodes also cover every `for` head now that loops accept the full
; irrefutable-pattern grammar.
(binding_pattern (identifier) @local.definition.var)
(binding_subpattern name: (identifier) @local.definition.var)

; Top-level / item definitions.
(function_definition name: (identifier) @local.definition.function)
(const_definition name: (identifier) @local.definition.constant)
(struct_definition name: (identifier) @local.definition.type)
(enum_definition name: (identifier) @local.definition.type)
(type_alias name: (identifier) @local.definition.type)

; Control-flow labels are distinct from value bindings in Moon-aware clients.
(loop_label name: (identifier) @local.definition.label)
(break_statement label: (identifier) @local.reference)
(continue_statement label: (identifier) @local.reference)

; -- references -------------------------------------------------------------
(identifier) @local.reference
