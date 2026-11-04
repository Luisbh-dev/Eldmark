package legal

import (
	"bytes"
	"context"
	"errors"
	"os"
	"testing"
	"testing/fstest"

	"eldmark/platform/internal/testdb"
)

func TestMain(m *testing.M) { os.Exit(testdb.Main(m)) }

const draftHeader = "Borrador pendiente de revisión legal; no es asesoramiento jurídico"

func TestEmbeddedDrafts(t *testing.T) {
	s, err := Load(Embedded())
	if err != nil {
		t.Fatal(err)
	}
	for _, kind := range Kinds {
		d := s.Current(kind)
		if d == nil || d.Version != 1 || !bytes.Contains(d.Text, []byte(draftHeader)) {
			t.Fatalf("%s: %+v", kind, d)
		}
	}
	// privacy-1.md reflects the retention table from plataforma.md §11.1.
	privacy := string(s.Current("privacy").Text)
	for _, want := range []string{"30 días", "1 año", "14 días", "35 días", "HMAC", "7 días", "1 día", "90 días",
		"desde que se purga", "instancias de zona terminadas", "dato de moderación"} {
		if !bytes.Contains([]byte(privacy), []byte(want)) {
			t.Errorf("privacy-1.md no dice %q", want)
		}
	}
	if s.Current("otro") != nil {
		t.Fatal("tipo desconocido")
	}
}

func TestLoadPicksTheLatest(t *testing.T) {
	fsys := fstest.MapFS{
		"terms-1.md":   {Data: []byte("uno")},
		"terms-2.md":   {Data: []byte("dos")},
		"privacy-1.md": {Data: []byte("p")},
		"rules-1.md":   {Data: []byte("r")},
		"README.md":    {Data: []byte("se ignora")},
		"terms-x.md":   {Data: []byte("se ignora")},
	}
	s, err := Load(fsys)
	if err != nil {
		t.Fatal(err)
	}
	if v := s.Versions(); v["terms"] != 2 || v["privacy"] != 1 || v["rules"] != 1 {
		t.Fatalf("vigentes: %v", v)
	}
	if s.Current("terms").FileName() != "terms-2.md" {
		t.Fatal(s.Current("terms").FileName())
	}
	delete(fsys, "rules-1.md")
	if _, err := Load(fsys); err == nil {
		t.Fatal("sin normas no arranca")
	}
	fsys["rules-1.md"] = &fstest.MapFile{Data: []byte{0xff, 0xfe}}
	if _, err := Load(fsys); err == nil {
		t.Fatal("un texto que no es UTF-8 no arranca")
	}
}

func TestSync(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	s, err := Load(Embedded())
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		if changed, err := s.Sync(ctx, pool, true); err != nil || len(changed) != 0 {
			t.Fatalf("vuelta %d: %v %v", i, changed, err)
		}
	}
	var n int
	if err := pool.QueryRow(ctx, `select count(*) from legal_documents`).Scan(&n); err != nil || n != 3 {
		t.Fatalf("filas: %d %v", n, err)
	}
	// A published text that changes: in staging and production it does not start; in dev and test, a warning.
	edited := fstest.MapFS{
		"terms-1.md":   {Data: []byte("otro texto")},
		"privacy-1.md": {Data: s.Current("privacy").Text},
		"rules-1.md":   {Data: s.Current("rules").Text},
	}
	e, _ := Load(edited)
	if _, err := e.Sync(ctx, pool, true); !errors.Is(err, ErrChanged) {
		t.Fatalf("estricto: %v", err)
	}
	if changed, err := e.Sync(ctx, pool, false); err != nil || len(changed) != 1 || changed[0] != "terms-1.md" {
		t.Fatalf("dev: %v %v", changed, err)
	}
}
