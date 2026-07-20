package fido

import "lib"

Ref :: struct {
	id:         lib.Id,
	generation: u32,
}

Property :: enum {
	None,
	Hierarchy,
	Show,
	Health,
}

PropertySet :: bit_set[Property]

Entity :: struct {
	ref:          Ref,
	property_set: PropertySet,
}

//
// Property Structs
//

PropertyData :: union {
	Hierarchy,
	Show,
	Health,
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

Model :: struct {
	entity:    lib.PackedArray(Entity),
	hierarchy: lib.PackedArray(Hierarchy),
	parent:    [dynamic]Ref,
	show:      lib.PackedArray(Show),
	health:    lib.PackedArray(Health),
}

deref :: proc(state: ^Model, ref: Ref) -> (id: lib.Id, is_valid: bool) {
	if ref.id == 0 do return
	entity := lib.packed_get_ptr(&state.entity, ref.id) or_return
	return ref.id, ref == entity.ref
}

entity_new :: proc(model: ^Model, id: lib.Id) -> Ref {
	entity := Entity {
		ref = Ref{id = id},
	}
	ptr, is_ok := lib.packed_try_insert(&model.entity, id, entity)

	// if insertion fails because there already is data there
	if (!is_ok) {
		idx := model.entity.idx[id]
		ptr := &model.entity.slots[idx].data
		ptr.ref.generation += 1
	}

	return ptr.ref
}

entity_rmv_soft :: proc(model: ^Model, ref: Ref) -> bool {
	id := deref(model, ref) or_return
	entity, _ := lib.packed_get_ptr(&model.entity, id)
	entity.ref.generation += 1
	return true
}

entity_rmv_hard :: proc(model: ^Model, ref: Ref) -> bool {
	id := deref(model, ref) or_return
	entity, _ := lib.packed_get_ptr(&model.entity, id)
	for prop in entity.property_set {
		prop_rmv(model, ref, prop)
	}
	lib.packed_remove(&model.entity, ref.id)
	return true
}

has_property :: #force_inline proc(model: ^Model, property: Property, id: lib.Id) -> bool {
	entity, _ := lib.packed_get_ptr(&model.entity, id)
	return property in entity.property_set
}

prop_add :: proc(model: ^Model, ref: Ref, data: PropertyData) -> bool {
	id := deref(model, ref) or_return
	property := data_to_property(data)
	if has_property(model, property, id) do return false
	switch val in data {
	case Hierarchy:
		lib.packed_try_insert(&model.hierarchy, id, val)
	case Show:
		lib.packed_try_insert(&model.show, id, val)
	case Health:
		lib.packed_try_insert(&model.health, id, val)
	}

	model.entity.slots[id].data.property_set |= {property}
	return true
}

prop_rmv :: proc(model: ^Model, ref: Ref, property: Property) -> bool {
	id := deref(model, ref) or_return
	if !has_property(model, property, id) do return false

	switch property {
	case .Hierarchy:
		child_rmv(model, id)
	case .Show:
		lib.packed_remove(&model.show, id)
	case .Health:
		lib.packed_remove(&model.health, id)
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

child_rmv :: proc(model: ^Model, id: lib.Id) -> bool {
	child := lib.packed_get_ptr(&model.hierarchy, id) or_return
	parent_id, _ := deref(model, model.parent[id])
	parent, _ := lib.packed_get_ptr(&model.hierarchy, parent_id)

	sentinel := &model.hierarchy.slots[0].data
	head := parent.first_kid
	// if the head of the list is child, get the new head
	new_head := head == child ? child.next_sib : head
	// ..and if new head is still the child, list has only one member.
	// Default to sentinel
	parent.first_kid = new_head == child ? sentinel : new_head
	child.prev_sib.next_sib = child.next_sib
	child.next_sib.prev_sib = child.prev_sib

	model.parent[id] = {}
	lib.packed_remove(&model.hierarchy, id)
	return true
}

// Insert child as the first kid of the parent
//
child_prepend :: proc(model: ^Model, parent_ref: Ref, child_ref: Ref) -> bool {
	// you can't contain yourself!
	if parent_ref == child_ref do return false

	parent_id := deref(model, parent_ref) or_return
	child_id := deref(model, child_ref) or_return
	child := lib.packed_get_ptr(&model.hierarchy, child_id) or_return
	parent := lib.packed_get_ptr(&model.hierarchy, parent_id) or_return

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

	child := lib.packed_get_ptr(&model.hierarchy, child_id) or_return
	parent := lib.packed_get_ptr(&model.hierarchy, parent_id) or_return

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
