package forwarding

import (
	"strings"
	"testing"
)

func TestPolicyMatching(t *testing.T) {
	rules, err := compilePolicy(`
# Physical comment.
notify-send \
    {{.*}}
virsh start {{dev-linux|dev-windows}}
podman run --rm --name test-{{[a-z0-9-]+}} approved-image
sample '--code={{([0-9]{2})}}' "two words" '' \{\{literal}} <literal> #
sample {{[[:alpha:]]+}} '{{\{x\}}}'
sample {{^z$}}
`+"space {{[[:space:]]}}\nnegate {{[^y]}}\nbytes {{^\xff.$}}\n", nil)
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
		_, err := compilePolicy(tc.text, map[string]bool{"ssh": true})
		if err == nil || !strings.Contains(err.Error(), "line "+tc.line+":") {
			t.Errorf("%q: want error on line %s, got %v", tc.text, tc.line, err)
		}
	}
	rules, err := compilePolicy("cmd {{.*}}\ncmd yes\n", nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := rules.authorize([]string{"cmd", "yes"}); err == nil || !strings.Contains(err.Error(), "multiple") {
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
		rules, err := compilePolicy("cmd {{"+pattern+"}}", nil)
		if err != nil {
			t.Fatalf("%s: %v", pattern, err)
		}
		if err := rules.authorize([]string{"cmd", strings.Repeat("a", 1000)}); err != nil {
			t.Errorf("%s did not match: %v", pattern, err)
		}
	}
	for _, pattern := range []string{`(a{1001})`, `((a{10}){101})`, `((a{1,11}){100,})`, `((a{11,}){1,100})`, `((a{1001}){0,})`} {
		if _, err := compilePolicy("cmd {{"+pattern+"}}", nil); err == nil {
			t.Errorf("accepted %s", pattern)
		}
	}
}
