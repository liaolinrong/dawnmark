[
  "architecture" "begin" "case" "else" "elsif" "end" "entity" "for"
  "function" "generate" "generic" "if" "in" "is" "library" "loop" "map"
  "of" "out" "package" "port" "procedure" "process" "return" "signal"
  "then" "type" "use" "variable" "when"
] @keyword

(comment) @comment
[(string_literal) (character_literal) (bit_string_literal)] @string
[(integer_decimal) (real_decimal)] @number
(type_mark) @type