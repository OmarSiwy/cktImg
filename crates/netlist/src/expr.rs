//! A small arithmetic evaluator for `.param` and `{...}` brace expressions in device value
//! labels. Supports SPICE SI-suffixed numbers, identifiers resolved from a scope map, `+ - * /`,
//! unary minus, and parentheses. It exists only to turn a value *label* like `{2*rval}` into a
//! number — topology and pins never depend on it, so an unresolvable expression simply leaves
//! the raw text in place rather than failing the parse.

use std::collections::HashMap;

/// Resolved parameter scope: name -> value. SPICE names are lowercased before insertion.
pub type Scope = HashMap<String, f64>;

/// Split a leading numeric literal off `s`, returning (value, rest). Accepts an optional
/// exponent (`1e-3`) but only when it is unambiguously an exponent (digit follows). `None` if
/// `s` has no numeric prefix.
fn split_num(s: &str) -> Option<(f64, &str)> {
    let b = s.as_bytes();
    let mut i = 0;
    let (mut dot, mut exp) = (false, false);
    while i < b.len() {
        let c = b[i] as char;
        if c.is_ascii_digit() {
            i += 1;
        } else if c == '.' && !dot && !exp {
            dot = true;
            i += 1;
        } else if (c == 'e' || c == 'E') && !exp && i > 0 {
            let mut j = i + 1;
            if j < b.len() && (b[j] == b'+' || b[j] == b'-') {
                j += 1;
            }
            if j < b.len() && (b[j] as char).is_ascii_digit() {
                exp = true;
                i = j; // consume e[sign]; the digit is taken next loop
            } else {
                break; // a bare 'e' is an SI/unit letter, not an exponent
            }
        } else {
            break;
        }
    }
    if i == 0 {
        return None;
    }
    s[..i].parse().ok().map(|v| (v, &s[i..]))
}

/// SPICE SI suffix multiplier. `meg`/`mil` are checked before the single-letter `m`. Trailing
/// unit letters after the suffix are ignored (`1kohm` -> 1000).
fn si_mult(suffix: &str) -> f64 {
    let prefix3 = |p: &str| suffix.get(..3).is_some_and(|s| s.eq_ignore_ascii_case(p));
    if prefix3("meg") {
        1e6
    } else if prefix3("mil") {
        25.4e-6
    } else {
        match suffix.chars().next().map(|c| c.to_ascii_lowercase()) {
            Some('t') => 1e12,
            Some('g') => 1e9,
            Some('k') => 1e3,
            Some('m') => 1e-3,
            Some('u') => 1e-6,
            Some('n') => 1e-9,
            Some('p') => 1e-12,
            Some('f') => 1e-15,
            Some('a') => 1e-18,
            _ => 1.0,
        }
    }
}

/// A SPICE number: float prefix + SI suffix. `None` if `s` doesn't start with a digit/dot.
/// Returns the value and the number of bytes consumed (mantissa + suffix letters).
fn read_number(s: &str) -> Option<(f64, usize)> {
    let (val, rest) = split_num(s)?;
    let suf_len: usize = rest
        .chars()
        .take_while(|c| c.is_ascii_alphabetic())
        .map(char::len_utf8)
        .sum();
    let consumed = s.len() - rest.len() + suf_len;
    Some((val * si_mult(&rest[..suf_len]), consumed))
}

#[derive(Clone, Debug, PartialEq)]
enum Tok {
    Num(f64),
    Ident(String),
    Op(char), // + - * / ( )
}

fn lex(s: &str) -> Option<Vec<Tok>> {
    let mut out = Vec::new();
    let mut rest = s;
    loop {
        rest = rest.trim_start();
        let Some(c) = rest.chars().next() else {
            break;
        };
        if matches!(c, '+' | '-' | '*' | '/' | '(' | ')') {
            out.push(Tok::Op(c));
            rest = &rest[1..];
        } else if c.is_ascii_digit() || c == '.' {
            let (v, n) = read_number(rest)?;
            out.push(Tok::Num(v));
            rest = &rest[n..];
        } else if c.is_ascii_alphabetic() || c == '_' {
            let n: usize = rest
                .chars()
                .take_while(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '.')
                .map(char::len_utf8)
                .sum();
            out.push(Tok::Ident(rest[..n].to_ascii_lowercase()));
            rest = &rest[n..];
        } else {
            return None; // unknown character
        }
    }
    Some(out)
}

struct Parser<'a> {
    t: Vec<Tok>,
    i: usize,
    scope: &'a Scope,
}

impl Parser<'_> {
    fn peek(&self) -> Option<&Tok> {
        self.t.get(self.i)
    }
    fn eat_op(&mut self, c: char) -> bool {
        if self.peek() == Some(&Tok::Op(c)) {
            self.i += 1;
            true
        } else {
            false
        }
    }
    fn additive(&mut self) -> Option<f64> {
        let mut v = self.term()?;
        loop {
            if self.eat_op('+') {
                v += self.term()?;
            } else if self.eat_op('-') {
                v -= self.term()?;
            } else {
                return Some(v);
            }
        }
    }
    fn term(&mut self) -> Option<f64> {
        let mut v = self.factor()?;
        loop {
            if self.eat_op('*') {
                v *= self.factor()?;
            } else if self.eat_op('/') {
                v /= self.factor()?;
            } else {
                return Some(v);
            }
        }
    }
    fn factor(&mut self) -> Option<f64> {
        if self.eat_op('-') {
            return self.factor().map(|v| -v);
        }
        if self.eat_op('+') {
            return self.factor();
        }
        if self.eat_op('(') {
            let v = self.additive()?;
            if !self.eat_op(')') {
                return None;
            }
            return Some(v);
        }
        match self.t.get(self.i)? {
            Tok::Num(n) => {
                let v = *n;
                self.i += 1;
                Some(v)
            }
            Tok::Ident(name) => {
                let v = self.scope.get(name).copied(); // unknown identifier -> whole eval fails
                self.i += 1;
                v
            }
            Tok::Op(_) => None,
        }
    }
}

/// Evaluate one expression string in a scope, or `None` if it references an unknown identifier
/// or is malformed.
pub fn eval(s: &str, scope: &Scope) -> Option<f64> {
    let toks = lex(s)?;
    if toks.is_empty() {
        return None;
    }
    let mut p = Parser {
        t: toks,
        i: 0,
        scope,
    };
    let v = p.additive()?;
    (p.i == p.t.len()).then_some(v) // trailing garbage -> reject
}

/// Format an evaluated number compactly for a label (no trailing-zero noise).
fn fmt(v: f64) -> String {
    // v == 0.0 also catches -0.0, which would otherwise print as "-0"
    if v == 0.0 {
        "0".to_string()
    } else {
        format!("{v}")
    }
}

/// Replace each `{expr}` in `value` with its evaluated number. Braces whose contents don't
/// evaluate (unknown param, syntax) are left verbatim, so a partially-parametric label degrades
/// gracefully. Non-brace text passes through untouched.
pub fn resolve_braces(value: &str, scope: &Scope) -> String {
    if !value.contains('{') {
        return value.to_string();
    }
    let mut out = String::with_capacity(value.len());
    let mut rest = value;
    while let Some(open) = rest.find('{') {
        out.push_str(&rest[..open]);
        let after = &rest[open + 1..];
        match after.find('}') {
            Some(close) => {
                let inner = &after[..close];
                match eval(inner, scope) {
                    Some(v) => out.push_str(&fmt(v)),
                    None => {
                        out.push('{');
                        out.push_str(inner);
                        out.push('}');
                    }
                }
                rest = &after[close + 1..];
            }
            None => {
                out.push_str(&rest[open..]); // unbalanced brace: emit the remainder as-is
                return out;
            }
        }
    }
    out.push_str(rest);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn si_numbers() {
        let e = Scope::new();
        assert_eq!(eval("1k", &e), Some(1000.0));
        assert_eq!(eval("4.7u", &e), Some(4.7e-6));
        assert_eq!(eval("2meg", &e), Some(2e6));
        assert_eq!(eval("1e-3", &e), Some(1e-3));
        assert_eq!(eval("5m", &e), Some(5e-3));
        assert_eq!(eval("abc", &e), None); // bare unknown ident
    }

    #[test]
    fn arithmetic_and_scope() {
        let mut sc = Scope::new();
        sc.insert("w".into(), 2e-6);
        sc.insert("n".into(), 3.0);
        assert_eq!(eval("2*3+1", &sc), Some(7.0));
        assert_eq!(eval("-(1+2)*2", &sc), Some(-6.0));
        assert_eq!(eval("w*n", &sc), Some(6e-6));
        assert_eq!(eval("1k/2", &sc), Some(500.0));
        assert_eq!(eval("missing+1", &sc), None);
        assert_eq!(eval("3 +", &sc), None);
    }

    #[test]
    fn braces() {
        let mut sc = Scope::new();
        sc.insert("rval".into(), 1000.0);
        assert_eq!(resolve_braces("{2*rval}", &sc), "2000");
        assert_eq!(resolve_braces("W={rval}m", &sc), "W=1000m");
        assert_eq!(resolve_braces("plain", &sc), "plain");
        assert_eq!(resolve_braces("{nope}", &sc), "{nope}"); // unresolved kept verbatim
    }
}
