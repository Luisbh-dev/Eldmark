// Package legal holds Eldmark's versioned legal texts (docs/platform.md §11.4): terms (terms-N.md),
// privacy (privacy-N.md) and community rules (rules-N.md), in Markdown.
//
// The files in this folder are embedded in the binary ([Embedded]); ELDMARK_LEGAL_DIR replaces
// them with those from another folder. On startup, the platform computes the SHA-256 of each
// version and inserts it into legal_documents if missing ([Set.Sync]). A published version does
// not change: a new text is a new file with the next number, and the account must accept it.
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

// Embedded returns the texts that are embedded in the binary.
func Embedded() fs.FS { return embedded }

// Text types, in the order they are shown.
var Kinds = []string{"terms", "privacy", "rules"}

// Document is a version of a text.
type Document struct {
	Kind    string
	Version int
	Text    []byte
	SHA256  [sha256.Size]byte
}

// FileName is the name of its file: terms-1.md.
func (d *Document) FileName() string { return d.Kind + "-" + strconv.Itoa(d.Version) + ".md" }

// Set is all the versions of the three texts.
type Set struct {
	byKind map[string][]*Document // from lowest to highest version
}

var fileName = regexp.MustCompile(`^(terms|privacy|rules)-([1-9][0-9]{0,5})\.md$`)

// Load reads the texts from fsys: the <type>-<version>.md files in its root (the others are
// ignored). Each type needs at least one version; the current one is the highest.
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

// Current returns the current version of a type, or nil if the type does not exist.
func (s *Set) Current(kind string) *Document {
	docs := s.byKind[kind]
	if len(docs) == 0 {
		return nil
	}
	return docs[len(docs)-1]
}

// Versions returns the current version of each type.
func (s *Set) Versions() map[string]int {
	out := make(map[string]int, len(Kinds))
	for _, kind := range Kinds {
		out[kind] = s.Current(kind).Version
	}
	return out
}

// DB is what Sync needs from the database: *pgxpool.Pool or pgx.Tx.
type DB interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// ErrChanged is the cause of the Sync error when an already published version has changed its text.
var ErrChanged = errors.New("legal: un texto ya publicado ha cambiado")

// Sync inserts the missing versions into legal_documents. If a version is already there with a
// different SHA-256, the published text has changed: with strict (staging and production) it is
// an error, because accounts accepted the earlier text; without it (dev and test) the checksum is
// updated and the version is returned in changed so it can be flagged in the log.
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
