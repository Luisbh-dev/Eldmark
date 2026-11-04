// Package e2e holds the platform's end-to-end tests (plataforma.md P10, §15): the real platform in
// the test process, with an ephemeral PostgreSQL (internal/testdb), and real Godot processes (a
// test_world zone with --platform and bots with an account).
//
// The tests carry the e2e build tag, so "go test ./..." does not see them:
//
//	cd platform && ELDMARK_GODOT=<path to Godot 4.7.2> go test -tags e2e -count=1 -v ./e2e
//
// Without ELDMARK_GODOT they are skipped (with ELDMARK_REQUIRE_GODOT=1, CI, they fail). TestMain
// imports the project once (godot --headless --import, with the LFS objects already downloaded).
// ELDMARK_E2E_ARTIFACTS=<folder> keeps the logs of each test there (the platform, the zones, the
// bots and their reports); without it they go to a temporary folder and, if the test fails, the end
// of each one is copied to its output. progress_test.go (progresion.md P8) uses the same harness for
// the inventory, the balances and the crash with economy operations.
package e2e
