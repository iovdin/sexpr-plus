sexpr = require \./index.js
parse = do
  parser = sexpr!
  ->
    s = parser.main.parse it
    if s.status then s.value
    else throw Error "Parse error: expected #{s.expected} at #{s.index}"

parse-with-modifications = (transformer, input) -->
  parser = sexpr!
  transformer.call null parser
  s = parser.main.parse input
  if s.status then s.value
  else throw Error "Parse error at offset #{s.index}: expected #{s.expected}"

test = (name, func) ->
  (require \tape) name, (t) ->
    func.call t   # Make `this` refer to tape's asserts
    t.end!        # Automatically end tests

# Because writing out all the '{ type : \list content : [ ... ]  }' stuff would
# be boring and unreadable, here's a dead simple DSL for simplifying that.
convert-toplevel = ->
  switch typeof! it
  | \Array => it.map convert
  | _ => convert it

convert = ->
  switch typeof! it
  | \Null   => null
  | \Array  => type : \list content : it.map convert
  | \String =>
    if it instanceof Object then type : \string content : it.to-string!
                            else type : \atom   content : it

  | otherwise =>
    throw Error "Test error; invalid convenience template (got #that)"

delete-location-data = ->
  if it is null then return it

  delete it.location
  if it.type is \list then it.content.for-each delete-location-data
  else if typeof! it is \Array then it.for-each delete-location-data
  return it

to = (input, output, description) -->

  output = convert-toplevel output

  test description, ->
    input
    |> parse
    |> delete-location-data
    |> @deep-equals _, output

test-with-modifications = (description, input, output, transformer) ->
  output = convert-toplevel output

  test description, ->
    input
    |> parse-with-modifications transformer
    |> delete-location-data
    |> @deep-equals _, output

#
# Basics
#

''    `to` []    <| "empty input"
' \t' `to` []    <| "empty input (just whitespace)"
'a'   `to` [ \a] <| "atom"
'"a"' `to` [ new String \a ] <| "string"
'()'  `to` [[]]   <| "empty list"
' a ' `to` [ \a ] <| "whitespace is insignificant"
'((a b c)(()()))'   `to` [[[\a \b \c] [[] []]]] <| "nested lists"
'((a b c) (() ()))' `to` [[[\a \b \c] [[] []]]] <| "nested lists with spacing"

'(a\nb)' `to` [[\a \b]] <| "newlines are not part of atoms"

'(a b)(a b)' `to` [[\a \b] [\a \b]] <| "multiple forms"
'()( )(\n)' `to` [[] [] []] <| "multiple empty forms"

'#!/bin/sh' `to` []            <| "lone shebang line ignored"
'#!' `to` []                   <| "lone empty shebang line ignored"
'\n#!sh' `to` [ "#!sh" ]       <| "shebang line not at beginning is atom"
'#!/bin/sh\n(a)' `to` [[ \a ]] <| "shebang line followed by form"

#
# Quoting operators
#

[ [\' \quote] [\` \quasiquote] [\, \unquote] [\,@ \unquote-splicing] ]
  .for-each ([c, name]) ->
    "#{c}a"      `to` [[name, \a]]              <| "#name'd atom"
    "#c\"a\""    `to` [[name, new String \a]]   <| "#name'd string"
    "#c()"       `to` [[name, []]]              <| "#name'd empty list"
    "#c(a b c)"  `to` [[name, [\a \b \c]]]      <| "#name'd list with contents"
    "(#{c}a)"    `to` [[[name, \a]]]            <| "#name'd atom in a list"
    "(a #c b)"   `to` [[\a [name, \b]]]         <| "whitespaced #name"
    "(a #c#c b)" `to` [[\a [name, [name, \b]]]] <| "consecutive #{name}s nest"
    "(a#{c}b)"   `to` [[\a [name, \b]]]         <| "#{name} acts as delimiter"

    test "#name with nothing to apply to is an error" ->
      (-> parse "(#c)") `@throws` sexpr.SyntaxError

#
# Special characters and escaping
#

char-escape = ->
  switch it
  | \\n => "\\n"
  | \\t => "\\t"
  | \\r => "\\r"
  | _   => it

[ \' \` \" \; \\ " " '"' "\n" "\t" ] .for-each (c) ->
  "a\\#{c}b" `to` [ "a#{c}b" ]
    <| "escaped #{char-escape c} in an atom should parse"

[ \" "\\" ] .for-each (c) ->
  "\"a\\#{c}b\"" `to` [ new String "a#{c}b" ]
    <| "escaped #{char-escape c} in a string should parse"

[ [\b "\b"] [\f "\f"] [\n "\n"] [\r "\r"] [\t "\t"] [\v "\v"] [\0 "\0"] ]
  .for-each ([char, escapedChar]) ->
    "\"a\\#{char}b\"" `to` [ new String "a#{escapedChar}b" ]
    <| "strings may contain \\#{char} escape"

test "special characters work" ->
  <[ + / * £ $ % ^ & あ ]>.for-each ->
    it `to` [ it ] <| "special character #it works as atom"

#
# Comments
#

";hi" `to` []                <| "only 1 comment"
";hi\na" `to` [ "a" ]        <| "comment, then atom"
";hi\n;yo" `to` []           <| "only comments"
"(\n; a\n;b\n\n)" `to` [[]]  <| "empty list with comments inside"
"();hi" `to` [[]]            <| "comment immediately following list"
"a;hi" `to` [ "a" ]          <| "comment immediately following atom"
";(a comment)" `to` []       <| "comment looking like a form"
"(a ;)\nb)" `to` [ [\a \b] ] <| "form with close-paren-looking comment between"
'("a ;)"\n)' `to` [[new String "a ;)"]] <| "can't start comment in string"

#
# Modifications
#
test-with-modifications do
  "Transformer can change paren style"
  "[a b c]"
  [ [ \a \b \c ] ]
  (p) ->

    # Replace the parsers for the open and close paren characters with
    # different ones, so lists are written as [ ... ] instead of ( ... ).

    p.replace do
      p.sub.basic.openParenChar
      p.parsimmon.string \[

    p.replace do
      p.sub.basic.closeParenChar
      p.parsimmon.string \]

test-with-modifications do
  "Transformer can reverse atoms"
  "olleh ereht"
  [ \hello \there ]
  (p) ->

    # Replace the atom parser with a clone of the same parser except with
    # content mapped through a string-reverse, so atoms are read backwards.

    p.replace do
      p.sub.composite.atom.main
      p.clone p.sub.composite.atom.main .map ->
        it.content .= split "" .reverse! .join ""
        return it

test-with-modifications do
  "Transformer can add alternative way of writing atom"
  "$a b"
  [ \a \b ]
  (p) ->

    # Add an alternative to the atom parser where atoms may optionally be
    # prepended by an ignored dollar sign.

    dollar-then-atom = p.parsimmon.string \$
      .then p.clone p.sub.composite.atom.main

    p.replace do
      p.sub.composite.atom.main
      p.parsimmon.alt do
        dollar-then-atom
        p.clone p.sub.composite.atom.main

test-with-modifications do
  "Transformer can introduce alternative parsing rules"
  '(f [a b c xyz\\[\\]])'
  [ [ \f [ \array \a \b \c 'xyz[]' ] ] ]
  (p) ->

    # Add a parser that parses [ ... ] into (array ...).

    # First we create the necessary parser, mapping every result through a
    # function that prepends the "array" atom to each of the parsed lists'
    # contents.

    string = p.parsimmon.string
    array-opener = p.sub.basic.lexeme (string \[)
    array-terminator = p.sub.basic.lexeme (string \])
    square-brackets-array-parser = array-opener
      .then p.sub.basic.list-content
      .skip array-terminator
      .mark!
      .map ->
        it.value.unshift {
          type : \atom
          content : \array
          location :
            start : it.start
            end : it.start
        }
        type : \list
        content : it.value
        location :
          start : it.start
          end  : it.end

    # Register that as an alternative for expressions.

    p.replace do
      p.sub.basic.expression
      p.parsimmon.alt do
        square-brackets-array-parser
        p.clone p.sub.basic.expression

    # So we don't lose the ability to use "[" and "]" in atoms, we also have to
    # add the two as alternatives to the parser of characters that need to be
    # escaped there.

    p.replace do
      p.sub.composite.atom.sub.charNeedingEscape
      p.parsimmon.alt do
        string \[
        string \]
        p.clone p.sub.composite.atom.sub.charNeedingEscape

test-with-modifications do
  "Transformer can add ASCII char escape type to strings"
  '"\\t\\x20"' # "\x20" is an ASCII hex escape for the space character
  [ (new String "\t ") ]
  (p) ->

    ascii-escape =
      p.sub.basic.escape-char             # Expect to see the escape character
                                          # ("\" unless another transformer has
                                          # changed it)
      .then p.parsimmon.string \x         # ... then an "x"
      .then p.parsimmon.regex /[0-9a-f]+/ # ... then a char code in hex
      .map ->
        # The string parser expects its sub-parsers to return strings, so we
        # turn the hex code into the corresponding real character.
        it
        |> parseInt _, 16
        |> String.from-char-code

    # We then replace the string parser's "escapedCharacter" sub-parser with an
    # "alt" (alternative) between our new kind of escaped-character parser and
    # itself.
    p.replace do
      p.sub.composite.string.sub.escaped-character
      p.parsimmon.alt do
        ascii-escape
        p.clone p.sub.composite.string.sub.escaped-character

test-with-modifications do
  "Transformer can parse dot property access "
  'a.b.c'
  [ [\. \a \b \c] ]
  (p) ->
    # Add a parser that parses . property notiation into (. properties).
    # First we create the necessary parser, mapping every result through a
    # function that prepends the "array" atom to each of the parsed lists'
    # contents.
    string = p.parsimmon.string
    lexeme = p.sub.basic.lexeme
    dot-char = string \.
    atom = p.sub.composite.atom.main
    object-property-parser = p.parsimmon
      .seq atom, dot-char.then(atom).atLeast(1)
      .mark!
      .map ->
        value = it.value[1]
        value.unshift it.value[0];
        value.unshift p.toAtomNode {
          value: \.,
          start: it.start,
          end: it.end
        }
        p.toListNode {
          value,
          start: it.start,
          end: it.end
        }
     #do
      #atom
      #.mark!
      #.map p.toAtomNode
      #.skip dot-char
      #character.atLeast
      #.map ->
        #it.value.unshift {
          #type : \atom
          #content : \array
          #location :
            #start : it.start
            #end : it.start
        #}
        #type : \list
        #content : it.value
        #location :
          #start : it.start
          #end  : it.end

    # Register that as an alternative for expressions.

    p.replace do
      p.sub.basic.expression
      p.parsimmon.alt do
        object-property-parser
        p.clone p.sub.basic.expression

    # So we don't lose the ability to use "."  in atoms, we also have to

    p.replace do
      p.sub.composite.atom.sub.charNeedingEscape
      p.parsimmon.alt do
        dot-char
        p.clone p.sub.composite.atom.sub.charNeedingEscape
#
# Location information
#

test "lone atom loc is correct" ->
  parse "hi"
    (typeof! ..) `@equals` \Array
    ..length is 1
    ..0
      ..type `@equals` \atom
      ..location
        ..start
          ..offset `@equals` 0
          ..line   `@equals` 1
          ..column `@equals` 1
        ..end
          ..offset `@equals` 2
          ..line   `@equals` 1
          ..column `@equals` 3

test "single-line string loc is correct" ->
  parse '"hi"'
    (typeof! ..) `@equals` \Array
    ..length is 1
    ..0
      ..type `@equals` \string
      ..location
        ..start
          ..offset `@equals` 0
          ..line   `@equals` 1
          ..column `@equals` 1
        ..end
          ..offset `@equals` 4
          ..line   `@equals` 1
          ..column `@equals` 5

test "multi-line string loc is correct" ->
  parse '"hi\nthere"'
    (typeof! ..) `@equals` \Array
    ..length is 1
    ..0
      ..type `@equals` \string
      ..location
        ..start
          ..offset `@equals` 0
          ..line   `@equals` 1
          ..column `@equals` 1
        ..end
          ..offset `@equals` 10
          ..line   `@equals` 2
          ..column `@equals` 7

test "string containing escapes has correct loc" ->
  parse '"\\n\\t"'
    (typeof! ..) `@equals` \Array
    ..length is 1
    ..0
      ..type `@equals` \string
      ..location
        ..start
          ..offset `@equals` 0
          ..line   `@equals` 1
          ..column `@equals` 1
        ..end
          ..offset `@equals` 6
          ..line   `@equals` 1
          ..column `@equals` 7

test "empty list loc is correct" ->
  parse '()'
    (typeof! ..) `@equals` \Array
    ..length is 1
    ..0
      ..type `@equals` \list
      ..location
        ..start
          ..offset `@equals` 0
          ..line   `@equals` 1
          ..column `@equals` 1
        ..end
          ..offset `@equals` 2
          ..line   `@equals` 1
          ..column `@equals` 3

test "2-element list loc is correct" ->
  parse '(a b)'
    (typeof! ..) `@equals` \Array
    ..length is 1
    ..0
      ..type `@equals` \list
      ..location
        ..start
          ..offset `@equals` 0
          ..line   `@equals` 1
          ..column `@equals` 1
        ..end
          ..offset `@equals` 5
          ..line   `@equals` 1
          ..column `@equals` 6

test "2-element list content loc is correct" ->
  parse '(a b)'
    (typeof! ..) `@equals` \Array
    ..length is 1
    ..0
      ..type `@equals` \list
      ..content
        ..0
          ..type `@equals` \atom
          ..location
            ..start
              ..offset `@equals` 1
              ..line   `@equals` 1
              ..column `@equals` 2
            ..end
              ..offset `@equals` 2
              ..line   `@equals` 1
              ..column `@equals` 3
        ..1
          ..type `@equals` \atom
          ..location
            ..start
              ..offset `@equals` 3
              ..line   `@equals` 1
              ..column `@equals` 4
            ..end
              ..offset `@equals` 4
              ..line   `@equals` 1
              ..column `@equals` 5

test "quote atom loc matches that of the quote character" ->
  [ [\' \quote] [\` \quasiquote] [\, \unquote] [\,@ \unquote-splicing] ]
    .for-each ([c, name]) ~>
      parse "#{c}a"
        (typeof! ..) `@equals` \Array
        ..length is 1
        ..0
          ..type `@equals` \list
          ..content.0
            ..type `@equals` \atom
            ..content `@equals` name
            ..location
              ..start
                ..offset `@equals` 0
                ..line   `@equals` 1
                ..column `@equals` 1
              ..end
                ..offset `@equals` c.length
                ..line   `@equals` 1
                ..column `@equals` (1 + c.length)

test "locations of multi-form parse are correct" ->
  parse '(a b) (c)'
    (typeof! ..) `@equals` \Array
    ..length is 2
    ..0
      ..type `@equals` \list
      ..content
        ..0
          ..type `@equals` \atom
          ..location
            ..start
              ..offset `@equals` 1
              ..line   `@equals` 1
              ..column `@equals` 2
            ..end
              ..offset `@equals` 2
              ..line   `@equals` 1
              ..column `@equals` 3
        ..1
          ..type `@equals` \atom
          ..location
            ..start
              ..offset `@equals` 3
              ..line   `@equals` 1
              ..column `@equals` 4
            ..end
              ..offset `@equals` 4
              ..line   `@equals` 1
              ..column `@equals` 5
    ..1
      ..type `@equals` \list
      ..content
        ..0
          ..type `@equals` \atom
          ..location
            ..start
              ..offset `@equals` 7
              ..line   `@equals` 1
              ..column `@equals` 8
            ..end
              ..offset `@equals` 8
              ..line   `@equals` 1
              ..column `@equals` 9

#
# Form errors
#

test "closing after the end is an error" ->
  (-> parse "())") `@throws` sexpr.SyntaxError

test "incomplete string is an error" ->
  (-> parse '"a') `@throws` sexpr.SyntaxError

test "incomplete form due to comment is an error" ->
  (-> parse '(a;)') `@throws` sexpr.SyntaxError

