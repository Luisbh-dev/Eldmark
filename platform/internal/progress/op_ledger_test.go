package progress_test

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"
	"testing"

	"eldmark/platform/internal/persistence"
	"eldmark/platform/internal/zones"
)

// Op returns the operation with its participants, who reverted it, its entries and events and the
// rows of the uids in its events (retired ones too), only to an instance where some participant
// holds its lease; Ledger paginates a character's entries, most recent first, with limit from 1 to 100.
func TestOpLedger(t *testing.T) {
	c := loadCases(t)
	w := newWorld(t, c)
	for i := 0; i < 3; i++ {
		_, body := c.step(t, "valid_reversal", i)
		if i >= 1 {
			// The DESTROY takes the whole stack of endurance: its uid is left retired.
			body = edit(t, body, func(m map[string]any) {
				for _, o := range m["ops"].([]any) {
					op := o.(map[string]any)
					if op["kind"].(json.Number).String() == "1" {
						op["items"].([]any)[0].(map[string]any)["count_delta"] = -2
					}
				}
				var kept []any
				for _, it := range m["items"].([]any) {
					if it.(map[string]any)["def_id"] != "potion_stamina" {
						kept = append(kept, it)
					}
				}
				m["items"] = kept
			})
		}
		if got, _ := w.apply(42, body); got != "applied" {
			t.Fatalf("step %d: %s", i, got)
		}
	}
	ctx := context.Background()
	inst, _ := zones.ParseUUID(c.InstanceID)
	other, _ := zones.ParseUUID(otherInstance(c))
	op := func(opID int64, instance [16]byte) (map[string]any, error) {
		raw, err := w.store.Op(ctx, w.pool, opID, instance)
		if err != nil {
			return nil, err
		}
		return decodeMap(t, raw)["op"].(map[string]any), nil
	}
	// With no lease on the instance, nothing.
	if _, err := op(1032, inst); !errors.Is(err, persistence.ErrNotFound) {
		t.Fatalf("without a lease: %v", err)
	}
	w.exec(`insert into character_leases (character_id, world_id, lease_id, zone_instance_id, claimed_by, expires_at)
		values (42, 1, gen_random_uuid(), $1, $1, now() + interval '30 s')`, c.InstanceID)
	gm, err := op(1032, inst)
	if err != nil {
		t.Fatal(err)
	}
	if gm["kind"].(json.Number).String() != "4" || gm["actor_account_id"] != "77" || gm["note"] != "devolución del fallo 12" ||
		gm["reversed_by"] != "1033" || gm["zone_id"] != "vado_gris" || gm["ref_op_id"] != nil ||
		!reflect.DeepEqual(gm["participants"], []any{"42"}) || len(gm["items"].([]any)) != 0 ||
		len(gm["instances"].([]any)) != 0 || gm["created_at_unix"].(json.Number).String() != id(c.NowUnix) {
		t.Fatalf("GM: %v", gm)
	}
	detail := gm["detail"].(map[string]any)
	entry := gm["ledger"].([]any)[0].(map[string]any)
	if detail["command"] != "currency_add" || entry["character_id"] != "42" || entry["seq"].(json.Number).String() != "2" ||
		entry["delta"].(json.Number).String() != "50" || entry["ref_id"] != "0" {
		t.Fatalf("GM: %v %v", detail, entry)
	}
	destroy, err := op(1030, inst)
	if err != nil {
		t.Fatal(err)
	}
	instances := destroy["instances"].([]any)
	stamina := instances[0].(map[string]any)
	if len(instances) != 1 || stamina["uid"] != "1029" || stamina["retired"] != true || stamina["def_id"] != "potion_stamina" ||
		stamina["count"].(json.Number).String() != "2" || stamina["seed"] != "0" || stamina["durability"] != nil ||
		destroy["reversed_by"] != nil || destroy["actor_account_id"] != nil {
		t.Fatalf("DESTROY: %v", destroy)
	}
	reversal, err := op(1033, inst)
	if err != nil || reversal["ref_op_id"] != "1032" || reversal["kind"].(json.Number).String() != "5" {
		t.Fatalf("REVERSAL: %v %v", reversal, err)
	}
	for _, tc := range []struct {
		opID     int64
		instance [16]byte
	}{{1032, other}, {9999, inst}} {
		if _, err := op(tc.opID, tc.instance); !errors.Is(err, persistence.ErrNotFound) {
			t.Errorf("Op(%d): %v", tc.opID, err)
		}
	}

	ledger := func(limit int, before int64) []any {
		raw, err := w.store.Ledger(ctx, w.pool, 42, limit, before)
		if err != nil {
			t.Fatal(err)
		}
		return decodeMap(t, raw)["entries"].([]any)
	}
	all := ledger(100, 0)
	var ops []string
	for _, e := range all {
		ops = append(ops, e.(map[string]any)["op_id"].(string))
	}
	// Most recent first: the REVERSAL, the GM and the two GAMEPLAY entries (merits and gold).
	if !reflect.DeepEqual(ops, []string{"1033", "1032", "1031", "1031"}) {
		t.Fatalf("ledger: %v", ops)
	}
	first := ledger(2, 0)
	cursor := first[1].(map[string]any)["entry_id"].(string)
	var before int64
	if err := json.Unmarshal([]byte(cursor), &before); err != nil {
		t.Fatal(err)
	}
	next := ledger(2, before)
	if len(first) != 2 || len(next) != 2 || !reflect.DeepEqual(append(first, next...), all) {
		t.Fatalf("pagination: %v and %v", first, next)
	}
	if e := all[0].(map[string]any); e["delta"].(json.Number).String() != "-50" || e["seq"].(json.Number).String() != "3" ||
		e["created_at_unix"].(json.Number).String() != id(c.NowUnix) || len(e) != 10 {
		t.Fatalf("entry: %v", e)
	}
	for _, limit := range []int{0, 101} {
		if _, err := w.store.Ledger(ctx, w.pool, 42, limit, 0); err == nil {
			t.Errorf("limit %d without error", limit)
		}
	}
	if _, err := w.store.Ledger(ctx, w.pool, 4242, 20, 0); !errors.Is(err, persistence.ErrNotFound) {
		t.Errorf("a character without progress: %v", err)
	}
	if got := ledger(20, 1); len(got) != 0 {
		t.Errorf("before the first: %v", got)
	}
}
