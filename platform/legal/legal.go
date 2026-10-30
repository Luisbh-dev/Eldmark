// Package legal guarda los textos legales versionados de Eldmark (plataforma.md §11.4): términos
// (terms-N.md), privacidad (privacy-N.md) y normas de la comunidad (rules-N.md), en Markdown.
//
// Los archivos de esta carpeta van dentro del binario ([Embedded]); ELDMARK_LEGAL_DIR los cambia
// por los de otra carpeta. Al arrancar, la plataforma calcula el SHA-256 de cada versión y la
// inserta en legal_documents si falta ([Set.Sync]). Una versión publicada no cambia: un texto
// nuevo es un archivo nuevo con el número siguiente, y la cuenta tiene que aceptarlo.
package legal

import (
	"context"
	"crypto/sha256"
	"embed"
	"errors"
	"fmt"
	"io/fs"
	"regexp"
	"sort"
	"strconv"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

//go:embed *.md
var embedded embed.FS

// Embedded devuelve los textos que van en el binario.
func Embedded() fs.FS { return embedded }

// Tipos de texto, en el orden en que se muestran.
var Kinds = []string{"terms", "privacy", "rules"}

// Document es una versión de un texto.
type Document struct {
	Kind    string
	Version int
	Text    []byte
	SHA256  [sha256.Size]byte
}

// FileName es el nombre de su archivo: terms-1.md.
func (d *Document) FileName() string { return d.Kind + "-" + strconv.Itoa(d.Version) + ".md" }

// Set son todas las versiones de los tres textos.
type Set struct {
	byKind map[string][]*Document // de menor a mayor versión
}

var fileName = regexp.MustCompile(`^(terms|privacy|rules)-([1-9][0-9]{0,5})\.md$`)

// Load lee los textos de fsys: los archivos <tipo>-<versión>.md de su raíz (los demás se
// ignoran). Cada tipo necesita al menos una versión; la vigente es la mayor.
func Load(fsys fs.FS) (*Set, error) {
	entries, err := fs.ReadDir(fsys, ".")
	if err != nil {
		return nil, fmt.Errorf("legal: %w", err)
	}
	s := &Set{byKind: map[string][]*Document{}}
	for _, e := range entries {
		m := fileName.FindStringSubmatch(e.Name())
		if e.IsDir() || m == nil {
			continue
		}
		text, err := fs.ReadFile(fsys, e.Name())
		if err != nil {
			return nil, fmt.Errorf("legal: %w", err)
		}
		if len(text) == 0 || !utf8.Valid(text) {
			return nil, fmt.Errorf("legal: %s está vacío o no es UTF-8", e.Name())
		}
		version, _ := strconv.Atoi(m[2])
		s.byKind[m[1]] = append(s.byKind[m[1]], &Document{Kind: m[1], Version: version, Text: text, SHA256: sha256.Sum256(text)})
	}
	for _, kind := range Kinds {
		docs := s.byKind[kind]
		if len(docs) == 0 {
			return nil, fmt.Errorf("legal: falta %s-1.md (o una versión posterior)", kind)
		}
		sort.Slice(docs, func(i, j int) bool { return docs[i].Version < docs[j].Version })
	}
	return s, nil
}

// Current devuelve la versión vigente de un tipo, o nil si el tipo no existe.
func (s *Set) Current(kind string) *Document {
	docs := s.byKind[kind]
	if len(docs) == 0 {
		return nil
	}
	return docs[len(docs)-1]
}

// Versions devuelve la versión vigente de cada tipo.
func (s *Set) Versions() map[string]int {
	out := make(map[string]int, len(Kinds))
	for _, kind := range Kinds {
		out[kind] = s.Current(kind).Version
	}
	return out
}

// DB es lo que Sync necesita de la base: *pgxpool.Pool o pgx.Tx.
type DB interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// ErrChanged es la causa del error de Sync cuando una versión ya publicada ha cambiado de texto.
var ErrChanged = errors.New("legal: un texto ya publicado ha cambiado")

// Sync inserta en legal_documents las versiones que faltan. Si una versión ya está con otro
// SHA-256, el texto publicado ha cambiado: con strict (staging y production) es un error, porque
// las cuentas aceptaron el texto anterior; sin él (dev y test) se actualiza la suma y se devuelve
// en changed para avisar en el registro.
func (s *Set) Sync(ctx context.Context, db DB, strict bool) (changed []string, err error) {
	for _, kind := range Kinds {
		for _, d := range s.byKind[kind] {
			if _, err := db.Exec(ctx, `insert into legal_documents (kind, version, sha256) values ($1, $2, $3)
				on conflict (kind, version) do nothing`, d.Kind, d.Version, d.SHA256[:]); err != nil {
				return changed, fmt.Errorf("legal: %s: %w", d.FileName(), err)
			}
			var stored []byte
			if err := db.QueryRow(ctx, `select sha256 from legal_documents where kind = $1 and version = $2`,
				d.Kind, d.Version).Scan(&stored); err != nil {
				return changed, fmt.Errorf("legal: %s: %w", d.FileName(), err)
			}
			if string(stored) == string(d.SHA256[:]) {
				continue
			}
			if strict {
				return changed, fmt.Errorf("%w: %s no es el texto publicado (su SHA-256 no es el de legal_documents); "+
					"un texto nuevo va en un archivo con la versión siguiente", ErrChanged, d.FileName())
			}
			if _, err := db.Exec(ctx, `update legal_documents set sha256 = $3 where kind = $1 and version = $2`,
				d.Kind, d.Version, d.SHA256[:]); err != nil {
				return changed, fmt.Errorf("legal: %s: %w", d.FileName(), err)
			}
			changed = append(changed, d.FileName())
		}
	}
	return changed, nil
}
