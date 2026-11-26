package forwarding

import (
	"slices"
	"strings"
	"testing"
)

func TestPolicyMatching(t *testing.T) {
	rules, err := compilePolicy(`
# Physical comment.
[notify-send]
allow \
    {{.*}}
[virsh]
allow start {{dev-linux|dev-windows}}
[podman]
allow run --rm --name test-{{[a-z0-9-]+}} approved-image
[sample]
allow "--code={{([0-9]{2})}}" "two words" '' \{\{literal}} <literal> #
allow {{[[:alpha:]]+}} "{{\{x\}}}"
allow {{^z$}}
`+"[space]\nallow {{[[:space:]]}}\n[negate]\nallow {{[^y]}}\n[bytes]\nallow {{^\xff.$}}\n", nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{
		{"notify-send", ""}, {"notify-send", "\xff\n\n ;$` "},
		{"virsh", "start", "dev-windows"},
		{"podman", "run", "--rm", "--name", "test-123", "approved-image"},
		{"sample", "--code=12", "two words", "", "{{literal}}", "<literal>", "#"},
		{"sample", "ABC", "{x}"}, {"sample", "z"},
		{"space", "\n"}, {"space", "\v"}, {"negate", "\n"}, {"bytes", "\xff\xfe"},
	} {
		if err := rules.authorize(args); err != nil {
			t.Errorf("%q rejected: %v", args, err)
		}
	}
	for _, args := range [][]string{
		{"notify-send"}, {"notify-send", "a", "--urgency=critical"},
		{"virsh", "start", "dev-linux\n"}, {"virsh", "start", "\ndev-windows"},
		{"virsh", "start", "xdev-linux"}, {"virsh", "start", "dev-windowsx"},
		{"podman", "run", "--rm", "--name", "test-A", "approved-image"},
		{"sample", "z\n"}, {"sample", "\xff", "{x}"}, {"other"}, {"space", "\xa0"},
		{"bytes", "\xffé"}, {"bytes", "é"},
	} {
		if err := rules.authorize(args); err == nil {
			t.Errorf("%q accepted", args)
		}
	}
}

func TestPolicyMalformed(t *testing.T) {
	for _, tc := range []struct{ text, line string }{
		{"cmd\\\n x\n", "1"}, {"cmd \\\n", "1"}, {"cmd \\\n# comment\n", "2"},
		{"cmd \\\n 'bad\n", "2"}, {"cmd \\\n {{[z-a]}}\n", "2"},
		{"cmd \"quote\\\n continued\"\n", "1"}, {"cmd {{a\\\n}}\n", "1"},
		{`cmd {{[0-9]{2}}}`, "1"}, {`cmd {{(a)\1}}`, "1"}, {`cmd {{\w}}`, "1"},
		{`cmd {{a*?}}`, "1"}, {`cmd {{a|}}`, "1"}, {"cmd \x00", "1"}, {"/bin/cmd", "1"},
		{`cmd {{[[.a.]]}}`, "1"}, {`cmd {{[[=a=]]}}`, "1"}, {`cmd {{[[:^alpha:]]}}`, "1"},
		{"cmd " + strings.Repeat("a", 513), "1"}, {"ssh command", "1"},
	} {
		text := tc.text
		line := tc.line
		if strings.HasPrefix(text, "cmd") {
			text = "[cmd]\nallow" + strings.TrimPrefix(text, "cmd")
			if line == "1" {
				line = "2"
			} else {
				line = "3"
			}
		} else if text == "ssh command" {
			text = "[ssh]\nallow command"
		}
		_, err := compilePolicy(text, map[string]bool{"ssh": true})
		if err == nil || !strings.Contains(err.Error(), "line "+line+":") {
			t.Errorf("%q: want error on line %s, got %v", tc.text, tc.line, err)
		}
	}
	rules, err := compilePolicy("[cmd]\nallow {{.*}}\nallow yes\n", nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := rules.authorize([]string{"cmd", "yes"}); err != nil {
		t.Errorf("ambiguity: %v", err)
	}
	rules, err = compilePolicy("# deny all", nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := rules.authorize([]string{"cmd"}); err == nil {
		t.Fatal("empty policy authorized a command")
	}
}

func TestPolicyCountedRepetition(t *testing.T) {
	for _, pattern := range []string{`(a{1000})`, `(a{01000,01000})`, `((a{10}){100})`, `((a{1,10}){100,})`, `((a{1000}){0,})`} {
		rules, err := compilePolicy("[cmd]\nallow {{"+pattern+"}}", nil)
		if err != nil {
			t.Fatalf("%s: %v", pattern, err)
		}
		if err := rules.authorize([]string{"cmd", strings.Repeat("a", 1000)}); err != nil {
			t.Errorf("%s did not match: %v", pattern, err)
		}
	}
	for _, pattern := range []string{`(a{1001})`, `((a{10}){101})`, `((a{1,11}){100,})`, `((a{11,}){1,100})`, `((a{1001}){0,})`} {
		if _, err := compilePolicy("[cmd]\nallow {{"+pattern+"}}", nil); err == nil {
			t.Errorf("accepted %s", pattern)
		}
	}
}

func TestSectionResolution(t *testing.T) {
	policy := `[cmd sub deep]
insert C ''
log all
[cmd unused]
insert not-used
[cmd]
insert A \
  'literal\{{value}}'
allow sub deep {{.*}}
allow sub ''
log unmatched
fallback false
[cmd sub]
insert B
fallback true
allow deep {{.*}}
["cmd" 'sub']
insert D
fallback true
[cmd 'sub' 'deep']
insert E
[cmd 'sub' '']
allow
[settings-only]
insert X
log all
[cmd 'square]']
allow
[cmd escaped\]]
allow
`
	rules, err := compilePolicy(policy, nil)
	if err != nil {
		t.Fatal(err)
	}
	if rules.hasRules("settings-only") {
		t.Fatal("settings-only command grants permission")
	}
	for _, tc := range []struct {
		args, want      []string
		match, fallback bool
		log             string
	}{
		{[]string{"cmd", "sub", "deep", "x"}, []string{"cmd", "A", `literal\{{value}}`, "sub", "B", "D", "deep", "C", "", "E", "x"}, true, true, "all"},
		{[]string{"cmd", "sub", "deep"}, []string{"cmd", "A", `literal\{{value}}`, "sub", "B", "D", "deep", "C", "", "E"}, false, true, "all"},
		{[]string{"cmd", "sub", ""}, []string{"cmd", "A", `literal\{{value}}`, "sub", "B", "D", ""}, true, true, "unmatched"},
		{[]string{"cmd", "option", "sub"}, []string{"cmd", "A", `literal\{{value}}`, "option", "sub"}, false, false, "unmatched"},
		{[]string{"other"}, []string{"other"}, false, true, "none"},
		{[]string{"settings-only"}, []string{"settings-only", "X"}, false, true, "all"},
	} {
		resolved, err := rules.resolve(tc.args)
		if err != nil || !slices.Equal(resolved.args, tc.want) || resolved.log != tc.log || resolved.fallback != tc.fallback || (rules.authorize(tc.args) == nil) != tc.match {
			t.Errorf("%q: %#v, %v", tc.args, resolved, err)
		}
	}
	for _, arg := range []string{"square]", "escaped]"} {
		if err := rules.authorize([]string{"cmd", arg}); err != nil {
			t.Error(err)
		}
	}
}

func TestSectionValidation(t *testing.T) {
	for _, invalid := range []string{
		"cmd argument", "allow anything", "[]", "[cmd] trailing", "[cmd {{x}}]", "[cmd \\\n word]", "[cmd]\nunknown", "[cmd]\ninsert", "[cmd]\ninsert {{.*}}", "[cmd]\nlog true", "[cmd]\nfallback maybe", "[cmd]\nlog all\n[cmd]\nlog none", "[cmd]\nfallback false\n[cmd]\nfallback true", "[cmd]\nallow \\\n# comment", "[cmd]\ninsert \\\n", "[cmd]\nallow 'unterminated",
	} {
		if _, err := compilePolicy(invalid, nil); err == nil {
			t.Errorf("accepted %q", invalid)
		}
	}
	if _, err := compilePolicy("[cmd]\nlog all\n[cmd]\nlog none", nil); err == nil || !strings.Contains(err.Error(), "line 4") || !strings.Contains(err.Error(), "line 2") {
		t.Fatalf("conflicting setting diagnostic: %v", err)
	}
	rules, err := compilePolicy("[cmd]\ninsert X\nallow {{.*}}", nil)
	if err != nil {
		t.Fatal(err)
	}
	args := []string{"cmd", strings.Repeat("x", 36858)}
	if _, err := rules.resolve(args); err == nil {
		t.Fatal("oversized inserted arguments accepted")
	}
}

func TestSectionOrder(t *testing.T) {
	root := "[cmd]\ninsert root\nallow sub {{.*}}\nlog unmatched\n"
	child := "[cmd sub]\ninsert child\nallow value\nfallback false\n"
	args := []string{"cmd", "sub", "value"}
	for _, text := range []string{root + child, child + root} {
		rules, err := compilePolicy(text, nil)
		if err != nil {
			t.Fatal(err)
		}
		got, err := rules.resolve(args)
		if err != nil || !slices.Equal(got.args, []string{"cmd", "root", "sub", "child", "value"}) || got.log != "unmatched" || got.fallback || rules.authorize(args) != nil {
			t.Fatalf("section order affected result: %#v %v", got, err)
		}
	}
}
