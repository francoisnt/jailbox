package forwarding

import (
	"errors"
	"fmt"
	"regexp"
	"regexp/syntax"
	"slices"
	"sort"
	"strconv"
	"strings"

	"github.com/francoisnt/jailbox/internal/argv"
)

const policyLimit = 32768
const patternLimit = 512

var commandName = regexp.MustCompile(`^[A-Za-z0-9_][A-Za-z0-9_.+-]{0,127}$`)
var interval = regexp.MustCompile(`^\{([0-9]+)(,([0-9]*))?\}`)

type argument struct {
	literal string
	pattern string
}

type section struct {
	words        []string
	rules        [][]argument
	inserts      []string
	log          string
	logLine      int
	fallback     *bool
	fallbackLine int
}

type policy map[string][]*section

var errUnmatched = errors.New("request does not match the host command policy")

func (sections policy) hasRules(name string) bool {
	for _, section := range sections[name] {
		if len(section.rules) > 0 {
			return true
		}
	}
	return false
}

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
		case quote == '\'' && char != '\'':
			literal.WriteByte(char)
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

// headerWords scans the closing delimiter using the same quote and escape
// conventions as the argument lexer. Regex fragments are not header words.
func headerWords(line string) ([]string, error) {
	var quote byte
	for i := 1; i < len(line); i++ {
		c := line[i]
		switch {
		case quote == '\'' && c != '\'':
		case c == '\\':
			i++
		case (c == '\'' || c == '"') && (quote == 0 || quote == c):
			quote ^= c
		case c == ']' && quote == 0:
			if strings.Trim(line[i+1:], " \t") != "" {
				return nil, errors.New("unexpected text after section header")
			}
			parts, _, err := tokenize(line[1:i], false)
			if err != nil {
				return nil, err
			}
			return literalWords(parts)
		}
	}
	return nil, errors.New("unclosed section header")
}

func literalWord(parts []fragment) (string, error) {
	if len(parts) != 1 || parts[0].regex {
		return "", errors.New("expected literal argument")
	}
	return parts[0].text, nil
}

func literalWords(parts [][]fragment) ([]string, error) {
	words := make([]string, 0, len(parts))
	for _, word := range parts {
		literal, err := literalWord(word)
		if err != nil {
			return nil, err
		}
		words = append(words, literal)
	}
	return words, nil
}

func compilePolicy(contents string, reserved map[string]bool) (policy, error) {
	if len(contents) > policyLimit {
		return nil, errors.New("HOST_COMMAND_POLICY exceeds 32768 bytes")
	}
	rules := make(policy)
	var current *section
	type locatedWord struct {
		parts []fragment
		line  int
	}
	var pending []locatedWord
	continued := false
	lines := strings.Split(contents, "\n")
	for i, line := range lines {
		diagnostic := func(err error) (policy, error) { return nil, fmt.Errorf("HOST_COMMAND_POLICY line %d: %w", i+1, err) }
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
		if !continued && strings.HasPrefix(trimmed, "[") {
			words, err := headerWords(trimmed)
			if err != nil {
				return diagnostic(err)
			}
			if len(words) == 0 || !commandName.MatchString(words[0]) {
				return diagnostic(errors.New("executable must be a literal command name"))
			}
			name := words[0]
			for _, word := range words[1:] {
				if len(word) > patternLimit {
					return diagnostic(errors.New("header argument is too long"))
				}
			}
			if reserved[name] {
				return diagnostic(fmt.Errorf("executable %s collides with a jailbox runtime helper", name))
			}
			current = nil
			for _, candidate := range rules[name] {
				if slices.Equal(candidate.words, words[1:]) {
					current = candidate
					break
				}
			}
			if current == nil {
				current = &section{words: words[1:]}
				rules[name] = append(rules[name], current)
			}
			continue
		}
		if current == nil {
			return diagnostic(errors.New("expected section header"))
		}
		words, next, err := tokenize(line, i < len(lines)-1)
		if err != nil {
			return diagnostic(err)
		}
		for _, word := range words {
			pending = append(pending, locatedWord{word, i + 1})
		}
		if len(pending) == 0 {
			return diagnostic(errors.New("expected section keyword"))
		}
		continued = next
		if continued {
			continue
		}
		keyword, err := literalWord(pending[0].parts)
		keywordLine := pending[0].line
		fromLine := func(line int, err error) (policy, error) {
			return nil, fmt.Errorf("HOST_COMMAND_POLICY line %d: %w", line, err)
		}
		if err != nil {
			return diagnostic(err)
		}
		values := pending[1:]
		pending = nil
		literals := func() ([]string, error) {
			var args []string
			for _, word := range values {
				literal, err := literalWord(word.parts)
				if err != nil {
					return nil, fmt.Errorf("line %d: %w", word.line, err)
				}
				args = append(args, literal)
			}
			return args, nil
		}
		switch keyword {
		case "allow":
			patterns := make([]argument, 0, len(values))
			for _, word := range values {
				pattern, err := argumentPattern(word.parts)
				if err != nil {
					return fromLine(word.line, err)
				}
				patterns = append(patterns, pattern)
			}
			current.rules = append(current.rules, patterns)
		case "insert":
			args, err := literals()
			if err != nil {
				return diagnostic(err)
			}
			if len(args) == 0 {
				return diagnostic(errors.New("insert requires arguments"))
			}
			current.inserts = append(current.inserts, args...)
		case "log", "fallback":
			args, err := literals()
			if err != nil {
				return diagnostic(err)
			}
			if len(args) != 1 {
				return diagnostic(errors.New("expected one setting value"))
			}
			if keyword == "log" {
				if args[0] != "none" && args[0] != "unmatched" && args[0] != "all" {
					return diagnostic(errors.New("invalid log setting"))
				}
				if current.log != "" && current.log != args[0] {
					return diagnostic(fmt.Errorf("conflicting log setting (line %d)", current.logLine))
				}
				current.log, current.logLine = args[0], keywordLine
			} else {
				if args[0] != "true" && args[0] != "false" {
					return diagnostic(errors.New("invalid fallback setting"))
				}
				value := args[0] == "true"
				if current.fallback != nil && *current.fallback != value {
					return diagnostic(fmt.Errorf("conflicting fallback setting (line %d)", current.fallbackLine))
				}
				current.fallback, current.fallbackLine = &value, keywordLine
			}
		default:
			return fromLine(keywordLine, fmt.Errorf("unknown section keyword %q", keyword))
		}
	}
	for _, sections := range rules {
		sort.Slice(sections, func(i, j int) bool { return len(sections[i].words) < len(sections[j].words) })
	}
	return rules, nil
}

func matchesHeader(words, args []string) bool {
	return len(words) <= len(args) && slices.Equal(words, args[:len(words)])
}

func (rules policy) authorize(args []string) error {
	mapped := make([]string, len(args)-1)
	for _, section := range rules[args[0]] {
		if !matchesHeader(section.words, args[1:]) {
			continue
		}
		values := args[1+len(section.words):]
	definitions:
		for _, patterns := range section.rules {
			if len(patterns) != len(values) {
				continue
			}
			for i, pattern := range patterns {
				if pattern.pattern == "" {
					if values[i] != pattern.literal {
						continue definitions
					}
					continue
				}
				compiled, err := regexp.Compile(pattern.pattern)
				if err != nil {
					return fmt.Errorf("regular expression matching failed: %w", err)
				}
				index := len(section.words) + i
				if mapped[index] == "" {
					mapped[index] = byteRunes(values[i])
				}
				if !compiled.MatchString(mapped[index]) {
					continue definitions
				}
			}
			return nil
		}
	}
	return errUnmatched
}

type resolution struct {
	args     []string
	log      string
	fallback bool
}

func (rules policy) resolve(args []string) (resolution, error) {
	result := resolution{args: []string{args[0]}, log: "none", fallback: true}
	used := 0
	for _, section := range rules[args[0]] {
		if !matchesHeader(section.words, args[1:]) {
			continue
		}
		result.args = append(result.args, args[1+used:1+len(section.words)]...)
		used = len(section.words)
		result.args = append(result.args, section.inserts...)
		if section.log != "" {
			result.log = section.log
		}
		if section.fallback != nil {
			result.fallback = *section.fallback
		}
	}
	result.args = append(result.args, args[1+used:]...)
	_, err := argv.Encode("forwarded command with inserted arguments", result.args)
	return result, err
}
