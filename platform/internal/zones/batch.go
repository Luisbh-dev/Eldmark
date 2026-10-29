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

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"eldmark/platform/internal/db"
	"eldmark/platform/internal/httpx"
	"eldmark/platform/internal/jsonx"
)

// Batch es un lote de la zona (§6, «Lotes»): {zone_instance_id, <campo>: [{key, …}]}. Las
// entradas quedan crudas para validarlas una a una: una mala no tumba el lote.
type Batch struct {
	InstanceID string
	Entries    []json.RawMessage
}

// DecodeBatch lee un lote con las entradas en field («events», «messages» o «entries»). El objeto
// de fuera es estricto (otra clave o una que falta: 400 bad_request); las entradas no se miran aquí.
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

// Entry son los campos de una entrada de un lote, crudos.
type Entry map[string]json.RawMessage

// EntryKey lee la key de una entrada cruda aunque el resto no valga, para poder listarla en
// rejected; "" si no hay una cadena.
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

// ParseEntry lee una entrada con exactamente estas claves (todas presentes, ninguna más): «se
// rechaza la que no trae un campo» (§6).
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

// String lee un campo de texto.
func (e Entry) String(field string) (string, bool) {
	var s string
	if err := json.Unmarshal(e[field], &s); err != nil {
		return "", false
	}
	return s, true
}

// Int lee un campo entero (jsonx.Int: admite 4.0).
func (e Entry) Int(field string) (int64, bool) {
	var v jsonx.Int
	if err := json.Unmarshal(e[field], &v); err != nil {
		return 0, false
	}
	return int64(v), true
}

// ID lee un campo id (cadena decimal); con nullable, null da (nil, true).
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

// Object lee un campo que tiene que ser un objeto JSON y lo devuelve crudo.
func (e Entry) Object(field string) (json.RawMessage, bool) {
	raw := bytes.TrimSpace(e[field])
	if len(raw) == 0 || raw[0] != '{' {
		return nil, false
	}
	var probe map[string]json.RawMessage
	if json.Unmarshal(raw, &probe) != nil {
		return nil, false
	}
	return json.RawMessage(raw), true
}

// BatchResponse escribe la respuesta de un lote: 204 si todas las entradas valían; si no, 200
// {rejected: [key…]} (las demás ya se insertaron).
func BatchResponse(w http.ResponseWriter, rejected []string) {
	if len(rejected) == 0 {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"rejected": rejected})
}

// MaxKeyLen acota la key de una entrada: «<uuid>:<n>» u «op:<op_id>» caben de sobra.
const MaxKeyLen = 64

var seqPattern = regexp.MustCompile(`^(0|[1-9][0-9]{0,18})$`)

// BlockSize es lo que da cada bloque de ids (uid_block_seq va de 1024 en 1024).
const BlockSize = 1024

// KeyChecker valida las key de las entradas de un lote contra la instancia que lo manda (§6): una
// «<uuid>:<n>» tiene que llevar el zone_instance_id del lote, y una «op:<op_id>» (solo donde se
// admite: la auditoría) tiene que caer en un bloque de id_blocks dado a esa instancia.
type KeyChecker struct {
	inst   *Instance
	q      Querier
	blocks []int64 // first_id de los bloques de la instancia; se leen al ver la primera op
	loaded bool
}

// NewKeyChecker prepara la validación de las key de un lote de la instancia.
func NewKeyChecker(inst *Instance, q Querier) *KeyChecker { return &KeyChecker{inst: inst, q: q} }

// Valid dice si la key vale. allowOp admite «op:<op_id>».
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

// Inserter es lo que inserta las filas de un lote: *pgxpool.Pool.
type Inserter interface {
	SendBatch(ctx context.Context, b *pgx.Batch) pgx.BatchResults
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}

// InsertEach inserta las filas de un lote con la misma sentencia (con on conflict do nothing, para
// que reenviar no duplique), todas en una ida y vuelta. Si alguna choca con una restricción (un
// error determinista: clase 23), ninguna queda escrita y se insertan de una en una para rechazar
// solo esas: devuelve sus claves. Cualquier otro error de la base se devuelve (el lote entero se
// reintenta).
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
	if db.Classify(err) != db.KindIntegrity {
		return nil, err
	}
	var rejected []string
	for i, args := range rows {
		if _, err := q.Exec(ctx, sql, args...); err != nil {
			if db.Classify(err) != db.KindIntegrity {
				return nil, err
			}
			rejected = append(rejected, keys[i])
		}
	}
	return rejected, nil
}
