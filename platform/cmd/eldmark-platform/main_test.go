package main

import (
	"bytes"
	"context"
	"os"
	"strings"
	"testing"

	"eldmark/platform/internal/config"
	"eldmark/platform/internal/testdb"
)

func TestMain(m *testing.M) { os.Exit(testdb.Main(m)) }

func runWith(t *testing.T, env map[string]string, args ...string) (int, string, string) {
	t.Helper()
	var stdout, stderr bytes.Buffer
	lookup := config.Lookup(func(k string) (string, bool) { v, ok := env[k]; return v, ok })
	code := run(context.Background(), args, lookup, &stdout, &stderr)
	return code, stdout.String(), stderr.String()
}

func TestUsage(t *testing.T) {
	for _, args := range [][]string{{}, {"frobnicar"}, {"migrate"}, {"migrate", "down"}, {"migrate", "down", "0"},
		{"migrate", "down", "x"}, {"migrate", "sideways"}, {"serve", "extra"}} {
		code, _, stderr := runWith(t, nil, args...)
		if code != exitUsage || !strings.Contains(stderr, "eldmark-platform") && !strings.Contains(stderr, "migrate down") {
			t.Errorf("%v: código %d, %q", args, code, stderr)
		}
	}
	if code, stdout, _ := runWith(t, nil, "help"); code != exitOK || !strings.Contains(stdout, "migrate status") {
		t.Errorf("help: %d %q", code, stdout)
	}
}

func TestConfigErrorsStopTheCommands(t *testing.T) {
	code, _, stderr := runWith(t, map[string]string{}, "serve")
	if code != exitError || !strings.Contains(stderr, "ELDMARK_DATABASE_URL") || !strings.Contains(stderr, "no arranca") {
		t.Fatalf("serve sin configuración: %d %q", code, stderr)
	}
	code, _, stderr = runWith(t, map[string]string{}, "migrate", "up")
	if code != exitError || !strings.Contains(stderr, "ELDMARK_DATABASE_URL") {
		t.Fatalf("migrate sin base: %d %q", code, stderr)
	}
}

func TestMigrateCommands(t *testing.T) {
	pool := testdb.NewEmpty(t)
	env := map[string]string{"ELDMARK_ENV": "test", "ELDMARK_DATABASE_URL": testdb.ConnString(pool)}

	code, stdout, _ := runWith(t, env, "migrate", "status")
	if code != exitError || !strings.Contains(stdout, "0001_accounts") || !strings.Contains(stdout, "pendiente") {
		t.Fatalf("status de una base vacía (pendientes → código 1): %d\n%s", code, stdout)
	}
	code, stdout, stderr := runWith(t, env, "migrate", "up")
	if code != exitOK || !strings.Contains(stdout, "Aplicada 0001_accounts") || !strings.Contains(stdout, "Aplicada 0006_privacy") {
		t.Fatalf("up: %d\n%s%s", code, stdout, stderr)
	}
	if code, stdout, _ = runWith(t, env, "migrate", "up"); code != exitOK || !strings.Contains(stdout, "No hay migraciones pendientes") {
		t.Fatalf("segundo up: %d %s", code, stdout)
	}
	code, stdout, _ = runWith(t, env, "migrate", "status")
	if code != exitOK || strings.Count(stdout, "aplicada") != 6 || !strings.Contains(stdout, "UTC") {
		t.Fatalf("status al día: %d\n%s", code, stdout)
	}
	if code, stdout, _ = runWith(t, env, "migrate", "down", "2"); code != exitOK ||
		!strings.Contains(stdout, "Deshecha 0006_privacy\nDeshecha 0005_social") {
		t.Fatalf("down 2: %d %s", code, stdout)
	}
	for _, e := range []string{"staging", "production"} {
		env["ELDMARK_ENV"] = e
		code, _, stderr = runWith(t, env, "migrate", "down", "1")
		if code != exitError || !strings.Contains(stderr, "solo se usa en desarrollo y CI") {
			t.Fatalf("down en %s: %d %q", e, code, stderr)
		}
	}
	env["ELDMARK_ENV"] = "dev"
	if code, _, stderr = runWith(t, env, "migrate", "down", "9"); code != exitError || !strings.Contains(stderr, "Error") {
		t.Fatalf("down de más: %d %q", code, stderr)
	}
}
