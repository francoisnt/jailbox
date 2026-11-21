package argv

import (
	"reflect"
	"strings"
	"testing"
)

func TestFrame(t *testing.T) {
	want := []string{"printf", "", "two words", "'\";$()", "\x00\xff"[1:], "a\nb\n"}
	frame, err := Encode("test", want)
	if err != nil {
		t.Fatal(err)
	}
	got, err := Decode(frame)
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("decoded %q, %v; want %q", got, err, want)
	}
	largest := strings.Repeat("a", 36858)
	frame, err = Encode("test", []string{"true", largest})
	if err != nil || len(frame) != Limit {
		t.Fatalf("frame boundary: %d, %v", len(frame), err)
	}
	if _, err := Decode(frame); err != nil {
		t.Fatal(err)
	}
	if _, err := Encode("test", []string{"true", largest + "x"}); err == nil {
		t.Fatal("encode accepted an oversized frame")
	}
	for _, bad := range []string{"", "AA==", "Y2F0", "Y2F0AA", "Y2F0\nAA==", "Y2F0AA==junk", frame + "AAAA"} {
		if _, err := Decode(bad); err == nil {
			t.Errorf("accepted malformed frame of %d bytes", len(bad))
		}
	}
}
