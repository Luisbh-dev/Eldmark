package logx

import (
	"bytes"
	"context"
	"encoding/json"
	"log/slog"
	"testing"
)

func TestMaskEmail(t *testing.T) {
	cases := map[string]string{
		"aneira@example.org": "a***@example.org",
		"a@example.org":      "a***@example.org",
		"x+y@sub.eldmark.es": "x***@sub.eldmark.es",
		"sin-arroba":         "***",
		"@example.org":       "***",
		"nadie@":             "***",
		"":                   "",
	}
	for in, want := range cases {
		if got := MaskEmail(in); got != want {
			t.Errorf("MaskEmail(%q) = %q, expected %q", in, got, want)
		}
	}
}

func TestRequestFieldsInTheJSONLog(t *testing.T) {
	var buf bytes.Buffer
	log := New(&buf, slog.LevelInfo)
	req := &Request{ID: NewRequestID()}
	if len(req.ID) != 16 {
		t.Fatalf("16-character request id: %q", req.ID)
	}
	ctx := WithRequest(context.Background(), req)
	SetAccount(ctx, 7)
	SetCharacter(ctx, 42)
	if RequestID(ctx) != req.ID {
		t.Fatal("RequestID returns the one from the context")
	}
	log.LogAttrs(ctx, slog.LevelInfo, "petición", req.Attrs()...)
	var line map[string]any
	if err := json.Unmarshal(buf.Bytes(), &line); err != nil {
		t.Fatalf("a JSON line: %v (%s)", err, buf.String())
	}
	for _, key := range []string{"time", "level", "msg", "req", "account", "character"} {
		if _, ok := line[key]; !ok {
			t.Errorf("field %s is missing in %s", key, buf.String())
		}
	}
	// Without a request context nothing happens.
	SetAccount(context.Background(), 1)
	if RequestID(context.Background()) != "" {
		t.Fatal("without a request there is no id")
	}
	if attrs := (&Request{ID: "x"}).Attrs(); len(attrs) != 1 {
		t.Fatalf("without account or character, only req: %v", attrs)
	}
}
