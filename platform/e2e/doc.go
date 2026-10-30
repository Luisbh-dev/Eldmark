// Package e2e son las pruebas de extremo a extremo de la plataforma (plataforma.md P10, §15): la plataforma
// de verdad en el proceso de la prueba, con un PostgreSQL efímero (internal/testdb), y procesos de Godot de
// verdad (una zona test_world con --platform y bots con cuenta).
//
// Las pruebas llevan la etiqueta de compilación e2e, así que «go test ./...» no las ve:
//
//	cd platform && ELDMARK_GODOT=<ruta de Godot 4.7.2> go test -tags e2e -count=1 -v ./e2e
//
// Sin ELDMARK_GODOT se saltan (con ELDMARK_REQUIRE_GODOT=1, la CI, fallan). TestMain importa el proyecto
// una vez (godot --headless --import, con los objetos de LFS ya bajados). ELDMARK_E2E_ARTIFACTS=<carpeta>
// conserva allí los registros de cada prueba (la plataforma, las zonas, los bots y sus informes); sin ella
// van a una carpeta temporal y, si la prueba falla, se copia el final de cada uno en su salida.
// progress_test.go (progresion.md P8) usa el mismo arnés para el inventario, los saldos y la caída con operaciones
// de la economía.
package e2e
