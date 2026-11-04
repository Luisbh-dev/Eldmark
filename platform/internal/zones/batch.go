package zones

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"eldmark/platform/internal/db"
	"eldmark/platform/internal/httpx"
	"eldmark/platform/internal/jsonx"
)

// Batch is a zone batch (§6, "Batches"): {zone_instance_id, <field>: [{key, …}]}. The entries
// stay raw so they can be validated one by one: a bad one does not bring down the batch.
type Batch struct {
	InstanceID string
	Entries    []json.RawMessage
}

// DecodeBatch reads a batch with the entries in field ("events", "messages" or "entries"). The
// outer object is strict (another key or a missing one: 400 bad_request); the entries are not
// looked at here.
func DecodeBatch(w http.ResponseWriter, r *http.Request, field string) (*Batch, *httpx.Error) {
	var outer map[string]json.RawMessage
	if e := Decode(w, r, &outer); e != nil {
		return nil, e
	}
	rawID, okID := outer["zone_instance_id"]
	rawEntries, okEntries := outer[field]
	if len(outer) != 2 || !okID || !okEntries {
		return nil, httpx.BadRequest()
	}
	b := &Batch{}
	if err := json.Unmarshal(rawID, &b.InstanceID); err != nil {
		return nil, httpx.BadRequest()
	}
	if err := json.Unmarshal(rawEntries, &b.Entries); err != nil || b.Entries == nil {
		return nil, httpx.BadRequest()
	}
	return b, nil
}

// Entry holds the fields of a batch entry, raw.
type Entry map[string]json.RawMessage

// EntryKey reads the key of a raw entry even if the rest is invalid, so it can be listed in
// rejected; "" if there is no string.
func EntryKey(raw json.RawMessage) string {
	var probe struct {
		Key json.RawMessage `json:"key"`
	}
	if json.Unmarshal(raw, &probe) != nil {
		return ""
	}
	var key string
	if json.Unmarshal(probe.Key, &key) != nil {
		return ""
	}
	return key
}

// ParseEntry reads an entry with exactly these keys (all present, no others): "an entry that
// lacks a field is rejected" (§6).
func ParseEntry(raw json.RawMessage, fields ...string) (Entry, bool) {
	var e Entry
	dec := json.NewDecoder(bytes.NewReader(raw))
	if err := dec.Decode(&e); err != nil || e == nil {
		return nil, false
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return nil, false
	}
	if len(e) != len(fields) {
		return nil, false
	}
	for _, f := range fields {
		if _, ok := e[f]; !ok {
			return nil, false
		}
	}
	return e, true
}

func isNull(raw json.RawMessage) bool { return string(bytes.TrimSpace(raw)) == "null" }

// String reads a text field.
func (e Entry) String(field string) (string, bool) {
	var s string
	if err := json.Unmarshal(e[field], &s); err != nil {
		return "", false
	}
	return s, true
}

// Int reads an integer field (jsonx.Int: accepts 4.0).
func (e Entry) Int(field string) (int64, bool) {
	var v jsonx.Int
	if err := json.Unmarshal(e[field], &v); err != nil {
		return 0, false
	}
	return int64(v), true
}

// ID reads an id field (decimal string); with nullable, null gives (nil, true).
func (e Entry) ID(field string, nullable bool) (*int64, bool) {
	raw := e[field]
	if isNull(raw) {
		return nil, nullable
	}
	var v jsonx.ID
	if err := json.Unmarshal(raw, &v); err != nil {
		return nil, false
	}
	id := int64(v)
	return &id, true
}

// Object reads a field that must be a JSON object that fits in jsonb ([IsJSONObject]) and
// returns it raw.
func (e Entry) Object(field string) (json.RawMessage, bool) {
	raw := bytes.TrimSpace(e[field])
	if !IsJSONObject(raw) {
		return nil, false
	}
	return json.RawMessage(raw), true
}

// IsJSONObject says whether raw is a JSON object that PostgreSQL stores in jsonb: valid UTF-8,
// without \u0000 and without lone \uD800–\uDFFF (22P05 in the database). encoding/json checks
// none of that: it accepted it and the database rejected it on insert.
func IsJSONObject(raw []byte) bool {
	raw = bytes.TrimSpace(raw)
	if len(raw) == 0 || raw[0] != '{' || !utf8.Valid(raw) {
		return false
	}
	var probe map[string]json.RawMessage
	if json.Unmarshal(raw, &probe) != nil {
		return false
	}
	return jsonbEscapes(raw)
}

// jsonbEscapes goes over the \u escapes of an already valid JSON: none is \u0000 and each high
// surrogate is followed by a low one (and no low one is lone). Outside strings there are no
// backslashes, so there is no need to track the quotes.
func jsonbEscapes(raw []byte) bool {
	hex4 := func(i int) (rune, bool) {
		if i+4 > len(raw) {
			return 0, false
		}
		v, err := strconv.ParseUint(string(raw[i:i+4]), 16, 16)
		return rune(v), err == nil
	}
	for i := 0; i < len(raw); i++ {
		if raw[i] != '\\' {
			continue
		}
		i++
		if i >= len(raw) || raw[i] != 'u' {
			continue // another single-character escape
		}
		r, ok := hex4(i + 1)
		i += 4
		switch {
		case !ok || r == 0 || (r >= 0xDC00 && r <= 0xDFFF):
			return false
		case r >= 0xD800 && r <= 0xDBFF:
			if i+2 >= len(raw) || raw[i+1] != '\\' || raw[i+2] != 'u' {
				return false
			}
			low, ok := hex4(i + 3)
			if !ok || low < 0xDC00 || low > 0xDFFF {
				return false
			}
			i += 6
		}
	}
	return true
}

// MaxUnix is the latest date a batch accepts (9999-12-31T23:59:59Z, that of a sanction with no
// end): a later one does not fit in timestamptz (22008) or pgx overflowed it silently.
const MaxUnix = 253402300799

// BatchResponse writes a batch's response: 204 if all entries were valid; otherwise 200
// {rejected: [key…]} (the rest were already inserted).
func BatchResponse(w http.ResponseWriter, rejected []string) {
	if len(rejected) == 0 {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"rejected": rejected})
}

// MaxKeyLen bounds an entry's key: "<uuid>:<n>" or "op:<op_id>" fit comfortably.
const MaxKeyLen = 64

var seqPattern = regexp.MustCompile(`^(0|[1-9][0-9]{0,18})$`)

// BlockSize is what each id block gives (uid_block_seq advances by 1024).
const BlockSize = 1024

// KeyChecker validates the keys of a batch's entries against the instance that sends it (§6): a
// "<uuid>:<n>" must carry the batch's zone_instance_id, and an "op:<op_id>" (only where it is
// allowed: audit) must fall in an id_blocks block given to that instance.
type KeyChecker struct {
	inst   *Instance
	q      Querier
	blocks []int64 // first_id of the instance's blocks; read on seeing the first op
	loaded bool
}

// NewKeyChecker prepares the validation of the keys of an instance's batch.
func NewKeyChecker(inst *Instance, q Querier) *KeyChecker { return &KeyChecker{inst: inst, q: q} }

// Valid says whether the key is valid. allowOp admits "op:<op_id>".
func (k *KeyChecker) Valid(ctx context.Context, key string, allowOp bool) (bool, error) {
	if key == "" || len(key) > MaxKeyLen {
		return false, nil
	}
	if rest, ok := strings.CutPrefix(key, "op:"); ok {
		if !allowOp {
			return false, nil
		}
		id, err := jsonx.ParseID(rest)
		if err != nil || id < 1 {
			return false, nil
		}
		return k.inBlock(ctx, int64(id))
	}
	prefix, seq, ok := strings.Cut(key, ":")
	if !ok || prefix != k.inst.IDString() || !seqPattern.MatchString(seq) {
		return false, nil
	}
	if _, err := strconv.ParseInt(seq, 10, 64); err != nil {
		return false, nil
	}
	return true, nil
}

func (k *KeyChecker) inBlock(ctx context.Context, id int64) (bool, error) {
	if !k.loaded {
		rows, err := k.q.Query(ctx, `select first_id from id_blocks where zone_instance_id = $1`, k.inst.ID)
		if err != nil {
			return false, err
		}
		for rows.Next() {
			var first int64
			if err := rows.Scan(&first); err != nil {
				rows.Close()
				return false, err
			}
			k.blocks = append(k.blocks, first)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return false, err
		}
		k.loaded = true
	}
	for _, first := range k.blocks {
		if id >= first && id < first+BlockSize {
			return true, nil
		}
	}
	return false, nil
}

// Inserter is what inserts a batch's rows: *pgxpool.Pool.
type Inserter interface {
	SendBatch(ctx context.Context, b *pgx.Batch) pgx.BatchResults
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}

// InsertEach inserts a batch's rows with the same statement (with on conflict do nothing, so
// resending does not duplicate), all in one round trip. If any fails with a deterministic error
// (a constraint, class 23, or data that PostgreSQL rejects, class 22: db.Deterministic), none is
// written and they are inserted one by one to reject only those: it returns their keys. Any other
// database error is returned (the whole batch is retried): an error in a single entry never
// jams the zone's queue (§6).
func InsertEach(ctx context.Context, q Inserter, sql string, rows [][]any, keys []string) ([]string, error) {
	if len(rows) == 0 {
		return nil, nil
	}
	b := &pgx.Batch{}
	for _, args := range rows {
		b.Queue(sql, args...)
	}
	err := q.SendBatch(ctx, b).Close()
	if err == nil {
		return nil, nil
	}
	if !db.Deterministic(err) {
		return nil, err
	}
	var rejected []string
	for i, args := range rows {
		if _, err := q.Exec(ctx, sql, args...); err != nil {
			if !db.Deterministic(err) {
				return nil, err
			}
			rejected = append(rejected, keys[i])
		}
	}
	return rejected, nil
}
