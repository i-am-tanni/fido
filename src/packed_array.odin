package fido

import "base:runtime"

// A Sparse-Dense Array
PackedArray :: struct($T: typeid) {
	// note: index 0 is sentinel
	// We use a reverse_idx to find the last slot id for unordered removes
	// The reason we cannot replace reverse_idx with simply an ID is once a
	// slot is removed, then we need to know the second to last ID, etc.
	//
	// Sparse Array - lookup by Id, contains the index for the dense array
	idx:   [dynamic]u32,
	// Dense Array - contains the data
	slots: [dynamic]DenseSlot(T),
}

Id :: distinct u32

DenseSlot :: struct($T: typeid) {
	id:   Id,
	data: T,
}

// Iterator for a Sparse-Dense Array
PackedIter :: struct($T: typeid) {
	index: int,
	data:  []DenseSlot(T),
}

// Initiate a packed array. You must specify how big you want your dense
// array capacity (i.e. how many slots you want to define from the outset)
// and the max_id you want to start with.
packed_init :: proc(
	packed: ^PackedArray($T),
	max_id: u32,
	dense_cap: u32,
	allocator: runtime.Allocator = context.allocator,
) {
	// len starts at 1 for a sentinel index
	packed^ = PackedArray(T) {
		slots = make([dynamic]DenseSlot(T), 1, dense_cap, allocator),
		idx   = make([dynamic]u32, max_id, allocator),
	}
}

packed_get_ptr :: proc(packed: ^PackedArray($T), id: Id) -> (slot: ^T, is_ok: bool) {
	idx := packed.idx[id]
	if idx == 0 do return
	return &packed.slots[idx].data, true
}

packed_try_insert :: proc(
	packed: ^PackedArray($T),
	id: Id,
	data: T,
) -> (
	slot: ^DenseSlot(T),
	is_ok: bool,
) {
	if id == 0 do return nil, false
	if len(packed.idx) <= int(id) {
		resize(&packed.idx, int(id) + 1)
	}
	index := len(packed.slots)
	packed.idx[id] = u32(index)
	append(&packed.slots, DenseSlot(T){id = id, data = data})
	slot = &packed.slots[index]
	return slot, slot != nil
}

packed_remove :: proc(packed: ^PackedArray($T), removed_id: Id) {
	assert(removed_id > 0)

	removed_index := packed.idx[removed_id]
	if (removed_index == 0) do return // safely exits if entity has no data
	len := len(packed.slots)
	assert(len > 1, "Packed array is empty!")

	last_index := u32(len - 1)

	if (removed_index != last_index) {
		// swap if the removed index is not the last
		// We manually do an unordered remove because we need
		last_id := packed.slots[last_index].id
		packed.idx[last_id] = removed_index
	}

	packed.idx[removed_id] = 0
	unordered_remove(&packed.slots, removed_index)
}

packed_array_to_iter :: proc(packed: ^PackedArray($T)) -> PackedIter(T) {
	// ignore sentinel
	return {index = 1, data = packed.slots[:]}
}

packed_iterator :: proc(it: ^PackedIter($T)) -> (val: DenseSlot(T), idx: int, cond: bool) {
	cond = it.index < len(it.data)

	for ; cond; cond = it.index < len(it.data) {
		val = it.data[it.index]
		idx = it.index
		it.index += 1
	}

	return
}
