package forwarding

import (
	"errors"
	"fmt"
	"regexp"
	"regexp/syntax"
	"strconv"
	"strings"
)

const policyLimit = 32768
const patternLimit = 512

var commandName = regexp.MustCompile(`^[A-Za-z0-9_][A-Za-z0-9_.+-]{0,127}$`)
var interval = regexp.MustCompile(`^\{([0-9]+)(,([0-9]*))?\}`)

type argument struct {
	literal string
	pattern string
}

type policy map[string][][]argument

// Map all 256 byte values to separate runes so Go's UTF-8 regular expression
// engine sees the same alphabet as a POSIX implementation in the C locale.
func byteRunes(value string) string {
	var mapped strings.Builder
	mapped.Grow(len(value))
	for i := 0; i < len(value); i++ {
		mapped.WriteRune(rune(value[i]))
	}
	return mapped.String()
}

func bracketEnd(pattern string, pos int) (int, error) {
	pos++
	if pos < len(pattern) && pattern[pos] == '^' {
		pos++
	}
	if pos < len(pattern) && pattern[pos] == ']' {
		pos++
	}
	for pos < len(pattern) {
		if pattern[pos] == ']' {
			return pos + 1, nil
		}
		switch {
		case strings.HasPrefix(pattern[pos:], "[."), strings.HasPrefix(pattern[pos:], "[="):
			return 0, errors.New("collating symbols and equivalence classes are unsupported")
		case strings.HasPrefix(pattern[pos:], "[:"):
			end := strings.Index(pattern[pos+2:], ":]")
			if end < 0 {
				return 0, errors.New("unterminated POSIX character class")
			}
			switch pattern[pos+2 : pos+2+end] {
			case "alnum", "alpha", "blank", "cntrl", "digit", "graph", "lower", "print", "punct", "space", "upper", "xdigit":
			default:
				return 0, errors.New("unknown POSIX character class")
			}
			pos += end + 4
		default:
			pos++
		}
	}
	return 0, errors.New("unterminated bracket expression")
}

func parseERE(pattern string) (*syntax.Regexp, error) {
	// Go also accepts empty alternatives, some escaped characters and brace
	// spellings that this policy grammar rejects. Track the maximum nested
	// count before the engine has a chance to simplify the expression.
	groups := []int{1}
	atom, branch := 0, false
	var normalized strings.Builder
	last := 0
	for pos := 0; pos < len(pattern); {
		char := pattern[pos]
		pos++
		switch {
		case char == '[':
			end, err := bracketEnd(pattern, pos-1)
			if err != nil {
				return nil, err
			}
			// POSIX treats backslash as an ordinary bracket character.
			normalized.WriteString(pattern[last : pos-1])
			normalized.WriteString(strings.ReplaceAll(pattern[pos-1:end], "\\", "\\\\"))
			last, pos = end, end
		case char == '\\':
			if pos == len(pattern) || !strings.ContainsRune(`.[^$()|*+?{}\`, rune(pattern[pos])) {
				return nil, errors.New("non-POSIX regex escape or backreference")
			}
			pos++
		case char == '(':
			groups = append(groups, 1)
			atom, branch = 0, false
			continue
		case char == ')':
			if len(groups) == 1 || !branch {
				return nil, errors.New("unbalanced or empty regex group")
			}
			atom = groups[len(groups)-1]
			groups = groups[:len(groups)-1]
			groups[len(groups)-1] = max(groups[len(groups)-1], atom)
			continue
		case char == '|':
			if !branch {
				return nil, errors.New("empty regex alternative")
			}
			atom, branch = 0, false
			continue
		case strings.ContainsRune("*+?{", rune(char)):
			if atom == 0 {
				return nil, errors.New("regex repetition needs an atom")
			}
			count := 1
			if char == '{' {
				match := interval.FindStringSubmatch(pattern[pos-1:])
				if match == nil {
					return nil, errors.New("invalid regex repetition")
				}
				lower, err := strconv.Atoi(match[1])
				if err != nil || lower > 1000 {
					return nil, errors.New("invalid regex repetition bounds")
				}
				count = lower
				if match[3] != "" {
					count, err = strconv.Atoi(match[3])
					if err != nil || count < lower || count > 1000 {
						return nil, errors.New("invalid regex repetition bounds")
					}
				}
				// The Go parser rejects leading zeroes in counts. Canonicalize
				// the validated POSIX bounds before handing them to the engine.
				normalized.WriteString(pattern[last : pos-1])
				normalized.WriteByte('{')
				normalized.WriteString(strconv.Itoa(lower))
				if match[2] != "" {
					normalized.WriteByte(',')
					if match[3] != "" {
						normalized.WriteString(strconv.Itoa(count))
					}
				}
				normalized.WriteByte('}')
				pos += len(match[0]) - 1
				last = pos
			}
			count = max(count, 1)
			if atom*count > 1000 {
				return nil, errors.New("nested regex repetition exceeds 1000")
			}
			groups[len(groups)-1] = max(groups[len(groups)-1], atom*count)
			atom = 0
			continue
		case char == '^' || char == '$':
			atom, branch = 0, true
			continue
		}
		atom, branch = 1, true
	}
	if len(groups) != 1 || !branch {
		return nil, errors.New("empty or unbalanced regex")
	}
	normalized.WriteString(pattern[last:])
	expression, err := syntax.Parse(byteRunes(normalized.String()), syntax.POSIX|syntax.OneLine|syntax.ClassNL|syntax.DotNL)
	if err != nil {
		return nil, errors.New("invalid POSIX extended regular expression")
	}
	return expression, nil
}

type fragment struct {
	text  string
	regex bool
}

func regexEnd(line string, start int) (int, error) {
	for pos := start; pos < len(line); pos++ {
		if strings.HasPrefix(line[pos:], "}}") {
			return pos, nil
		}
		if line[pos] == '\\' {
			pos++
		}
	}
	return 0, errors.New("unclosed regex section")
}

func tokenize(line string, newline bool) ([][]fragment, bool, error) {
	var words [][]fragment
	var parts []fragment
	var literal strings.Builder
	var quote byte
	active := false
	for pos := 0; pos < len(line); pos++ {
		char := line[pos]
		switch {
		case char == '\\':
			pos++
			if pos == len(line) {
				if newline && quote == 0 && !active {
					return words, true, nil
				}
				return nil, false, errors.New("backslash at end of line must continue at an argument boundary")
			}
			literal.WriteByte(line[pos])
		case strings.HasPrefix(line[pos:], "{{"):
			end, err := regexEnd(line, pos+2)
			if err != nil {
				return nil, false, err
			}
			parts = append(parts, fragment{text: literal.String()}, fragment{text: line[pos+2 : end], regex: true})
			literal.Reset()
			pos = end + 1
		case (char == '\'' || char == '"') && (quote == 0 || quote == char):
			quote ^= char
		case (char == ' ' || char == '\t') && quote == 0:
			if active {
				words = append(words, append(parts, fragment{text: literal.String()}))
				parts = nil
				literal.Reset()
				active = false
			}
			continue
		default:
			literal.WriteByte(char)
		}
		active = true
	}
	if quote != 0 {
		return nil, false, errors.New("unclosed quote")
	}
	if active {
		words = append(words, append(parts, fragment{text: literal.String()}))
	}
	return words, false, nil
}

func argumentPattern(parts []fragment) (argument, error) {
	size := 0
	for _, part := range parts {
		size += len(part.text)
	}
	if size > patternLimit {
		return argument{}, errors.New("argument pattern is too long")
	}
	if len(parts) == 1 {
		return argument{literal: parts[0].text}, nil
	}
	var pattern strings.Builder
	pattern.WriteString(`\A`)
	for _, part := range parts {
		if !part.regex {
			pattern.WriteString(regexp.QuoteMeta(byteRunes(part.text)))
			continue
		}
		expression, err := parseERE(part.text)
		if err != nil {
			return argument{}, err
		}
		pattern.WriteString("(?:")
		pattern.WriteString(expression.String())
		pattern.WriteByte(')')
	}
	pattern.WriteString(`\z`)
	if _, err := syntax.Parse(pattern.String(), syntax.Perl); err != nil {
		return argument{}, fmt.Errorf("invalid combined argument pattern: %w", err)
	}
	return argument{pattern: pattern.String()}, nil
}

func compilePolicy(contents string, reserved map[string]bool) (policy, error) {
	if len(contents) > policyLimit {
		return nil, errors.New("HOST_COMMAND_POLICY exceeds 32768 bytes")
	}
	rules := make(policy)
	var name string
	var patterns []argument
	continued := false
	lines := strings.Split(contents, "\n")
	for i, line := range lines {
		diagnostic := func(err error) (policy, error) {
			return nil, fmt.Errorf("HOST_COMMAND_POLICY line %d: %w", i+1, err)
		}
		if strings.ContainsRune(line, 0) {
			return diagnostic(errors.New("NUL byte in policy"))
		}
		trimmed := strings.TrimLeft(line, " \t")
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			if continued {
				if i == len(lines)-1 && line == "" {
					return nil, fmt.Errorf("HOST_COMMAND_POLICY line %d: unfinished continuation", i)
				}
				return diagnostic(errors.New("blank line or comment inside continuation"))
			}
			continue
		}
		words, next, err := tokenize(line, i < len(lines)-1)
		if err != nil {
			return diagnostic(err)
		}
		for _, word := range words {
			if name == "" {
				if len(word) != 1 || !commandName.MatchString(word[0].text) {
					return diagnostic(errors.New("executable must be a literal command name"))
				}
				name = word[0].text
				if reserved[name] {
					return diagnostic(fmt.Errorf("executable %s collides with a jailbox runtime helper", name))
				}
				continue
			}
			pattern, err := argumentPattern(word)
			if err != nil {
				return diagnostic(err)
			}
			patterns = append(patterns, pattern)
		}
		continued = next
		if !continued {
			rules[name] = append(rules[name], patterns)
			name, patterns = "", nil
		}
	}
	return rules, nil
}

func (rules policy) authorize(args []string) error {
	found := false
	values := make([]string, len(args)-1)
definitions:
	for _, patterns := range rules[args[0]] {
		if len(patterns) != len(values) {
			continue
		}
		for i, pattern := range patterns {
			value := args[i+1]
			if pattern.pattern == "" {
				if value != pattern.literal {
					continue definitions
				}
				continue
			}
			if values[i] == "" {
				values[i] = byteRunes(value)
			}
			compiled, err := regexp.Compile(pattern.pattern)
			if err != nil {
				return fmt.Errorf("regular expression matching failed: %w", err)
			}
			if !compiled.MatchString(values[i]) {
				continue definitions
			}
		}
		if found {
			return errors.New("multiple policy definitions match this request")
		}
		found = true
	}
	if !found {
		return errors.New("request does not match the host command policy")
	}
	return nil
}
