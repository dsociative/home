/*! `tlaplus` grammar for highlight.js */
(function(){
  function tlaplus(hljs) {
    return {
      name: 'TLA+',
      aliases: ['tlaplus', 'tla'],
      keywords: {
        keyword:
          'MODULE EXTENDS VARIABLE VARIABLES CONSTANT CONSTANTS INSTANCE LOCAL ' +
          'THEOREM LEMMA PROPOSITION ASSUME ASSUMPTION AXIOM ' +
          'PROOF BY QED OBVIOUS OMITTED PICK HAVE TAKE WITNESS SUFFICES NEW ' +
          'LET IN IF THEN ELSE CASE OTHER CHOOSE ' +
          'ENABLED UNCHANGED SUBSET UNION DOMAIN EXCEPT WITH',
        literal: 'TRUE FALSE',
        built_in: 'Nat Int Real STRING BOOLEAN Infinity Seq'
      },
      contains: [
        hljs.QUOTE_STRING_MODE,
        hljs.C_NUMBER_MODE,
        {
          className: 'comment',
          begin: /\\\*/,
          end: /$/
        },
        hljs.COMMENT(/\(\*/, /\*\)/),
        {
          className: 'operator',
          begin: /\\(?:in|notin|subseteq|cup|cap|leq|geq|div|circ|E|A|EE|AA|o|X)\b/
        },
        {
          className: 'operator',
          begin: /==|\/\\|\\\/|=>|<=>|~|->|<-|\|->|#|\/=|::=|'|\[\]|<>|WF_|SF_/
        },
        {
          className: 'punctuation',
          begin: /<<|>>/
        }
      ]
    };
  }

  if (typeof hljs !== 'undefined') {
    hljs.registerLanguage('tlaplus', tlaplus);
  } else if (typeof module !== 'undefined') {
    module.exports = tlaplus;
  }
})();
