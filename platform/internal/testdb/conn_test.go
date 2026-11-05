package testdb

import "testing"

func TestWithDatabase(t *testing.T) {
	cases := map[string]string{
		"postgres://eldmark:clave@127.0.0.1:5432/postgres?sslmode=disable": "postgres://eldmark:clave@127.0.0.1:5432/t_1?sslmode=disable",
		"postgresql://eldmark@db/":                  "postgresql://eldmark@db/t_1",
		"host=/tmp/pg user=eldmark dbname=postgres": "host=/tmp/pg user=eldmark dbname=postgres dbname=t_1",
	}
	for in, want := range cases {
		if got := withDatabase(in, "t_1"); got != want {
			t.Errorf("withDatabase(%q) = %q, expected %q", in, got, want)
		}
	}
}
