'use strict';
var Parsimmon = require("parsimmon");
var regex = Parsimmon.regex;
var string = Parsimmon.string;
var lazy = Parsimmon.lazy;
var seq = Parsimmon.seq;
var alt = Parsimmon.alt;
var eof = Parsimmon.eof;
var succeed = Parsimmon.succeed;

// reduce side effects
function cloneLoc(loc) {
  return {
    line: loc.line,
    column: loc.column,
    offset: loc.offset
  }
}

var toStringNode = function(node) {
  return {
    type : "string",
    content : node.value.join(""),
    location : {
      start : cloneLoc(node.start),
      end : cloneLoc(node.end)
    }
  };
};
var toAtomNode = function(node) {

  var d = node.value;

  return {
    type : "atom",
    content : d.join ? d.join("") : d,
    location : {
      start : cloneLoc(node.start),
      end : cloneLoc(node.end)
    }
  };
};
var toListNode = function(node) {
  return {
    type : "list",
    content : node.value,
    location : {
      start : cloneLoc(node.start),
      end : cloneLoc(node.end)
    }
  };
};

var construct = function() {

var openParenChar = string("(");
var closeParenChar = string(")");
var commentChar = string(";");
var escapeChar = string('\\');
var stringDelimiterChar = string('"');
var quoteChar = string("'");
var quasiquoteChar = string("`");
var unquoteChar = string(",");
var unquoteSplicingModifierChar = string("@");
var whitespaceChar = regex(/\s/).desc("whitespace");
var whitespace = whitespaceChar.atLeast(1);

var endOfLineComment = commentChar
  .then(regex(/[^\n]*/))
  .skip(alt(string("\n"), eof))
  //.desc("end-of-line comment");

var optWhitespace = alt(endOfLineComment, whitespace).many();
var lexeme = function(p) { return p.skip(optWhitespace); };

var singleCharEscape = escapeChar
  .then(alt(
        string("b"),
        string("f"),
        string("n"),
        string("r"),
        string("t"),
        string("v"),
        string("0"),
        escapeChar))
  .map(function(c) {
    switch (c) {
      case "b": return "\b";
      case "f": return "\f";
      case "n": return "\n";
      case "r": return "\r";
      case "t": return "\t";
      case "v": return "\v";
      case "0": return "\0";
      default : return c;
    }
  });


var charNot = function() {

  var args = [].slice.call(arguments);

  return Parsimmon.custom(function(success, failure) {
    return function(stream, i) {

      var someParserMatches = args.some(function(p) {
        return p._(stream, i).status;
      });

      //console.log(someParserMatches, stream, i);

      if ((! someParserMatches) && (i < stream.length)) {
        return success(i+1, stream.charAt(i));
      } else {
        return failure(i, "anything that doesn't match " + args);
      }
    };
  });
};

var stringParser = (function() {

  var delimiter = stringDelimiterChar;

  var escapedDelimiter = escapeChar.then(delimiter);
  var escapedChar = alt(escapedDelimiter, singleCharEscape);

  var normalChar = charNot(delimiter, escapeChar);

  var character = alt(normalChar, escapedChar);

  var content = character.many()//.desc("string content");

  var main = lexeme(
    (delimiter
      .then(content)
      .skip(delimiter)
      .mark()
      .map(toStringNode)
      //.desc("string literal")
  ));

  return {
    main : main,
    sub : {
      delimiter : delimiter,
      escapedDelimiter : escapedDelimiter,
      escapedCharacter : escapedChar,
      normalCharacter : normalChar,
      anyCharacter : character,
      content : content
    }
  };
})();

var atomParser = (function() {

  var needEscape = [
    commentChar,
    stringDelimiterChar,
    quoteChar,
    quasiquoteChar,
    unquoteChar,
    escapeChar,
    openParenChar,
    closeParenChar,
    whitespaceChar
  ];
  var charNeedingEscape = alt.apply(null, needEscape);
  var escapedChar = escapeChar.then(charNeedingEscape);
  var normalChar = charNot(charNeedingEscape);

  var character = alt(escapedChar, normalChar);

  var main = lexeme(
    character.atLeast(1)
      .mark()
      .map(toAtomNode)
      //.desc("atom")
  );
  return {
    main : main,
    sub : {
      charNeedingEscape : charNeedingEscape,
      escapedCharacter : escapedChar,
      normalCharacter : normalChar,
      anyCharacter : character
    }
  };
})();

var listOpener = lexeme(openParenChar)//.desc("opening paren");
var listTerminator = lexeme(closeParenChar)//.desc("closing paren");

var listParserLater = Parsimmon.custom(function() {});
var quotedExpressionParserLater = Parsimmon.custom(function() {});
var expression = alt(
  listParserLater,
  atomParser.main,
  stringParser.main,
  quotedExpressionParserLater
);

var listContent = expression.many()//.desc("list content");
var list = listOpener.then(listContent).skip(listTerminator)
  .mark()
  .map(toListNode);
listParserLater._ = list._;

var quotedExpressionParser = (function () {
  var quote = quoteChar
    .then(succeed("quote"))
    .mark().map(toAtomNode);
  var quasiquote = quasiquoteChar
    .then(succeed("quasiquote"))
    .mark().map(toAtomNode);
  var unquote = unquoteChar
    .then(succeed("unquote"))
    .mark().map(toAtomNode);
  var unquoteSplicing = unquoteChar.then(unquoteSplicingModifierChar)
    .then(succeed("unquote-splicing"))
    .mark().map(toAtomNode);

  var anyQuote = alt(quote, quasiquote, unquoteSplicing, unquote)
                  
  var main = seq(lexeme(anyQuote), expression)
    .mark().map(toListNode)
    //.desc("quoted expression");

  quotedExpressionParserLater._ = main._;

  return {
    main : main,
    sub : {
      quote : quote,
      quasiquote : quasiquote,
      unquote : unquote,
      unquoteSplicing : unquoteSplicing,
      anyQuote : anyQuote
    }
  };
})();

var shebangLine = regex(/^#![^\n]*/).skip(alt(string("\n"), eof))//.desc("shebang line");

var main = shebangLine.atMost(1)
  .then(optWhitespace)
  .then(expression.many());

var replace = function(parserToReplace, parserWithNewBehaviour) {
  parserToReplace._ = parserWithNewBehaviour._;
};
var clone = function(parserToClone) {
  return Parsimmon.custom(function(success, failure) {
    return parserToClone._;
  });
};

return {
  main : main,
  replace : replace,
  clone : clone,
  parsimmon : Parsimmon,
  sub : {
    basic : {
      lexeme : lexeme,
      openParenChar : openParenChar,
      closeParenChar : closeParenChar,
      commentChar : commentChar,
      escapeChar : escapeChar,
      stringDelimiterChar : stringDelimiterChar,
      quoteChar : quoteChar,
      quasiquoteChar : quasiquoteChar,
      unquoteChar : unquoteChar,
      unquoteSplicingModifierChar : unquoteSplicingModifierChar,
      whitespaceChar : whitespaceChar,
      whitespace : whitespace,
      endOfLineComment : endOfLineComment,
      shebangLine : shebangLine,
      list : list,
      listOpener : listOpener,
      listTerminator : listTerminator,
      listContent : listContent,
      singleCharEscape : singleCharEscape,
      expression : expression,
    },
    composite : {
      atom : atomParser,
      string : stringParser,
      quotedExpression : quotedExpressionParser,
    }
  },
  toAtomNode: toAtomNode,
  toStringNode: toStringNode,
  toListNode: toListNode
};

}; // end of constructor

module.exports = construct;
