package fido

import "core:container/queue"
import "core:fmt"
import "core:slice"
import "core:sync/chan"

MAX_DIR_VAL :: int(max(Direction))
MAX_ENTITY_ID :: 24

Ref :: struct {
	id:         Id,
	generation: u32,
}

Property :: enum {
	None,
	Hierarchy,
	Show,
	Health,
	Exitable,
	Player,
}

PropertySet :: bit_set[Property]

Entity :: struct {
	ref:          Ref,
	property_set: PropertySet,
}

Direction :: enum {
	Dir_None,
	Dir_North,
	Dir_South,
	Dir_East,
	Dir_West,
}

DirSet :: bit_set[Direction]

ExitData :: struct {
	to_ref:     Ref,
	direction:  Direction,
	is_deleted: bool,
}

//
// Property Structs
//

PropertyData :: union {
	Hierarchy,
	Show,
	Health,
	Exitable,
	Player,
}

// A cyclical double-linked list for nesting entities
Hierarchy :: struct {
	ref:       Ref,
	first_kid: ^Hierarchy,
	next_sib:  ^Hierarchy,
	prev_sib:  ^Hierarchy,
}

Show :: struct {
	name:  string,
	short: string,
	long:  string,
}

Health :: struct {
	hp:            i32,
	hp_max:        i32,
	hp_regen_rate: i32,
}

Exitable :: struct {
	exit_list_sorted: [dynamic; 8]ExitData,
	sparse:           [Direction]u8,
}

Player :: struct {
	conn_ref: ConnRef,
}

Model :: struct {
	entity:    PackedArray(Entity),
	hierarchy: PackedArray(Hierarchy),
	parent:    [dynamic]Ref,
	show:      PackedArray(Show),
	health:    PackedArray(Health),
	exit:      PackedArray(Exitable),
	player:    PackedArray(Player),
	free_list: queue.Queue(Id),
}

Room :: struct {
	name:  string,
	short: string,
	long:  string,
	id:    Id,
}

deref :: proc(state: ^Model, ref: Ref) -> (id: Id, is_valid: bool) {
	if ref.id == 0 do return
	entity := packed_get_ptr(&state.entity, ref.id) or_return
	return ref.id, ref == entity.ref
}

model_init :: proc(model: ^Model) {
	// Prepare
	packed_init(&model.entity, max_id = MAX_ENTITY_ID, dense_cap = MAX_ENTITY_ID)
	packed_init(&model.hierarchy, max_id = MAX_ENTITY_ID, dense_cap = MAX_ENTITY_ID)
	packed_init(&model.show, max_id = MAX_ENTITY_ID, dense_cap = MAX_ENTITY_ID)
	packed_init(&model.exit, max_id = MAX_ENTITY_ID, dense_cap = MAX_ENTITY_ID)
	packed_init(&model.player, max_id = MAX_ENTITY_ID, dense_cap = MAX_ENTITY_ID)
	model.parent = make([dynamic]Ref, MAX_ENTITY_ID, MAX_ENTITY_ID)

	// hierarchy has a special init step b/c we want to avoid using nulls for now
	sentinel := &model.hierarchy.slots[0].data

	sentinel^ = Hierarchy {
		first_kid = sentinel,
		next_sib  = sentinel,
		prev_sib  = sentinel,
	}

	// Populate
	ref1 := room_new(
		model,
		Room{name = "North Room", long = "It's warm up here.", short = "", id = 1},
	)
	ref2 := room_new(
		model,
		Room{name = "South Room", long = "It's cold down here.", short = "", id = 2},
	)
	exit_add(&model.exit, ref1.id, ExitData{to_ref = ref2, direction = .Dir_South})
	exit_add(&model.exit, ref2.id, ExitData{to_ref = ref1, direction = .Dir_North})
}

entity_new_assign_id :: proc(model: ^Model) -> Ref {
	id, ok := queue.pop_front_safe(&model.free_list)
	if !(ok) {
		id = Id(len(model.entity.slots))
	}
	return entity_new(model, id)
}

entity_new :: proc(model: ^Model, id: Id) -> Ref {
	entity := Entity {
		ref = Ref{id = id},
	}
	ptr, is_ok := packed_try_insert(&model.entity, id, entity)

	// if insertion fails because there already is data there
	if (!is_ok) {
		idx := model.entity.idx[id]
		ptr := &model.entity.slots[idx].data
		ptr.ref.generation += 1
	}

	return ptr.data.ref
}

entity_rmv_soft :: proc(model: ^Model, ref: Ref) -> bool {
	id := deref(model, ref) or_return
	entity, _ := packed_get_ptr(&model.entity, id)
	entity.ref.generation += 1
	queue.push_back(&model.free_list, ref.id)
	for prop in entity.property_set {
		prop_rmv(model, ref, prop)
	}
	return true
}

entity_rmv_hard :: proc(model: ^Model, ref: Ref) -> bool {
	id := deref(model, ref) or_return
	entity, _ := packed_get_ptr(&model.entity, id)
	for prop in entity.property_set {
		prop_rmv(model, ref, prop)
	}
	packed_remove(&model.entity, ref.id)
	queue.push_back(&model.free_list, ref.id)
	for prop in entity.property_set {
		prop_rmv(model, ref, prop)
	}
	return true
}

has_property :: #force_inline proc(model: ^Model, property: Property, id: Id) -> bool {
	entity, _ := packed_get_ptr(&model.entity, id)
	return property in entity.property_set
}

prop_add :: proc(model: ^Model, ref: Ref, data: PropertyData) -> bool {
	id := deref(model, ref) or_return
	property := data_to_property(data)
	if has_property(model, property, id) do return false
	switch val in data {
	case Hierarchy:
		packed_try_insert(&model.hierarchy, id, val)
	case Show:
		packed_try_insert(&model.show, id, val)
	case Health:
		packed_try_insert(&model.health, id, val)
	case Exitable:
		packed_try_insert(&model.exit, id, val)
	case Player:
		packed_try_insert(&model.player, id, val)
	}

	model.entity.slots[id].data.property_set |= {property}
	return true
}

prop_rmv :: proc(model: ^Model, ref: Ref, property: Property) -> bool {
	id := deref(model, ref) or_return
	if !has_property(model, property, id) do return false

	switch property {
	case .Hierarchy:
		child_prop_rmv(model, id)
	case .Show:
		packed_remove(&model.show, id)
	case .Health:
		packed_remove(&model.health, id)
	case .Exitable:
		packed_remove(&model.exit, id)
	case .Player:
		packed_remove(&model.player, id)
	case .None: // do nothing
	}

	model.entity.slots[id].data.property_set &~= {property}

	return true
}

data_to_property :: proc(data: PropertyData) -> Property {
	switch tag in data {
	case Hierarchy:
		return .Hierarchy
	case Show:
		return .Show
	case Health:
		return .Health
	case Exitable:
		return .Exitable
	case Player:
		return .Player
	case:
		return .None
	}
}

hierarchy_init :: proc(model: Model, hierarchy: ^Hierarchy) {
	sentinel := &model.hierarchy.slots[0].data
	hierarchy^ = {
		first_kid = sentinel,
		next_sib  = sentinel,
		prev_sib  = sentinel,
	}
}

child_move :: proc(model: ^Model, child_ref: Ref, to_parent: Ref) -> bool {
	id := deref(model, child_ref) or_return
	child_rmv(model, id) or_return
	child_prepend(model, to_parent, child_ref) or_return
	return true
}

child_prop_rmv :: proc(model: ^Model, id: Id) -> bool {
	ok := child_rmv(model, id)
	model.parent[id] = {}
	packed_remove(&model.hierarchy, id)
	return ok
}

child_rmv :: proc(model: ^Model, id: Id) -> bool {
	child := packed_get_ptr(&model.hierarchy, id) or_return
	parent_id, _ := deref(model, model.parent[id])
	parent, _ := packed_get_ptr(&model.hierarchy, parent_id)

	sentinel := &model.hierarchy.slots[0].data
	head := parent.first_kid
	// if the head of the list is child, get the new head
	new_head := head == child ? child.next_sib : head
	// ..and if new head is still the child, list has only one member.
	// Default to sentinel
	parent.first_kid = new_head == child ? sentinel : new_head
	child.prev_sib.next_sib = child.next_sib
	child.next_sib.prev_sib = child.prev_sib
	return true
}

// Insert child as the first kid of the parent
//
child_prepend :: proc(model: ^Model, parent_ref: Ref, child_ref: Ref) -> bool {
	// you can't contain yourself!
	if parent_ref == child_ref do return false

	parent_id := deref(model, parent_ref) or_return
	child_id := deref(model, child_ref) or_return
	child := packed_get_ptr(&model.hierarchy, child_id) or_return
	parent := packed_get_ptr(&model.hierarchy, parent_id) or_return

	head := parent.first_kid
	sentinel := &model.hierarchy.slots[0].data

	is_empty := head == sentinel

	child.next_sib = is_empty ? child : head
	child.prev_sib = is_empty ? child : head.prev_sib
	child.prev_sib.next_sib = child
	child.next_sib.prev_sib = child
	parent.first_kid = child
	model.parent[child_id] = parent_ref
	return true
}

// Insert child as the last kid of the parent
//
child_append :: proc(model: ^Model, parent_ref: Ref, child_ref: Ref) -> bool {
	// you can't contain yourself!
	if parent_ref == child_ref do return false

	parent_id := deref(model, parent_ref) or_return
	child_id := deref(model, child_ref) or_return

	child := packed_get_ptr(&model.hierarchy, child_id) or_return
	parent := packed_get_ptr(&model.hierarchy, parent_id) or_return

	sentinel := &model.hierarchy.slots[0].data
	head := parent.first_kid

	is_empty := head == sentinel
	child.next_sib = is_empty ? child : head
	child.prev_sib = is_empty ? child : head.prev_sib
	child.next_sib.prev_sib = child
	child.prev_sib.next_sib = child

	parent.first_kid = is_empty ? child : head
	model.parent[child_id] = parent_ref

	return true
}

exit_add :: proc(packed: ^PackedArray(Exitable), id: Id, exit_data: ExitData) -> bool {
	if exit_data.direction == .Dir_None do return false
	data, ok := packed_get_ptr(packed, id)
	// if exit property does not exist for this id
	if !ok {
		new := Exitable{}
		append(&new.exit_list_sorted, ExitData{})
		packed_try_insert(packed, id, new)
		data, ok = packed_get_ptr(packed, id)
	}

	// since exits are sorted, search for index to inject
	idx, found := slice.binary_search_by(
	data.exit_list_sorted[:],
	exit_data.direction,
	proc(it: ExitData, key: Direction) -> slice.Ordering {
		// sort exits in reverse order (1 == largest, etc.)
		if int(it.direction) > int(key) do return .Greater
		if int(it.direction) < int(key) do return .Less
		return .Equal
	},
	)

	if (found) {
		data.exit_list_sorted[idx] = exit_data
		return true
	}
	data.sparse[exit_data.direction] = u8(idx)
	inject_at(&data.exit_list_sorted, idx, exit_data)

	return true
}

exit_rmv :: proc(data: ^Exitable, direction: Direction) -> bool {
	idx := data.sparse[direction]
	data.sparse[direction] = 0
	// ordered removal invalidates our sparse indexes, but retains sorting
	ordered_remove(&data.exit_list_sorted, idx)
	//..so shift the sparse values as well
	len := u8(len(data.exit_list_sorted))
	for i := idx; i < len; i += 1 {
		elem := data.exit_list_sorted[i]
		data.sparse[elem.direction] -= 1
	}
	return true
}

exit_get :: proc(exits: ^Exitable, direction: Direction) -> (^ExitData, bool) {
	idx := exits.sparse[direction]
	if idx == 0 do return nil, false
	exit_data := &exits.exit_list_sorted[idx]
	return exit_data, true
}

is_player :: proc(model: Model, id: Id) -> bool {
	return model.player.idx[id] > 0
}

room_new :: proc(model: ^Model, room: Room) -> Ref {
	ref := entity_new(model, room.id)
	hierarchy := Hierarchy{}
	hierarchy_init(model^, &hierarchy)
	hierarchy.ref = ref
	exits := Exitable{}
	append(&exits.exit_list_sorted, ExitData{})
	prop_add(model, ref, hierarchy)
	prop_add(model, ref, Show{room.name, room.short, room.long})
	prop_add(model, ref, exits)
	return ref
}

player_new :: proc(model: ^Model, data: Player) -> Ref {
	ref := entity_new_assign_id(model)
	hierarchy := Hierarchy{}
	hierarchy_init(model^, &hierarchy)
	hierarchy.ref = ref
	prop_add(model, ref, hierarchy)
	prop_add(model, ref, data)
	prop_add(model, ref, Show{short = "A player is here.", long = "", name = "Player"})
	return ref
}

send :: proc(model: ^Model, ref: Ref, bytes: string) -> bool {
	id := deref(model, ref) or_return
	player := packed_get_ptr(&model.player, id) or_return
	chan.send(
		output_channel,
		UserOutput {
			id = 64,
			conn_ref = player.conn_ref,
			game_ref = ref,
			msg = bytes,
			is_terminating = false,
		},
	)
	return true
}
