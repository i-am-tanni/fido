package game

import "base:runtime"
import "core:fmt"

// A Sparse-Dense Array
SparseSet :: struct($T: typeid) {
	// note: index 0 is sentinel
	// We use a reverse_idx to find the last slot id for unordered removes
	// The reason we cannot replace reverse_idx with simply an ID is once a
	// slot is removed, then we need to know the second to last ID, etc.
	//
	// Dense Array - contains the data
	dense:  [dynamic]T,
	// Sparse Array - lookup by Id, contains the index for the dense array
	sparse: [dynamic]u32,
	id:     [dynamic]Id,
}

// An SoA Sparse-Dense Array
SoaSet :: struct($T: typeid) {
	// note: index 0 is sentinel
	// We use a reverse_idx to find the last slot id for unordered removes
	// The reason we cannot replace reverse_idx with simply an ID is once a
	// slot is removed, then we need to know the second to last ID, etc.
	//
	// Dense Array - contains the data
	dense:  #soa[dynamic]T,
	// Sparse Array - lookup by Id, contains the index for the dense array
	sparse: [dynamic]u32,
	id:     [dynamic]Id,
}

// Iterator for a Sparse-Dense Array
SparseSetIter :: struct($T: typeid) {
	index: int,
	data:  []DenseSlot(T),
}

// Iterator for an SoA Sparse-Dense Array
SoASparseSetIter :: struct($T: typeid) {
	index: int,
	data:  #soa[]DenseSlot(T),
}


// Initiate a sparse_set array. You must specify how big you want your dense
// array capacity (i.e. how many slots you want to define from the outset)
// and the max_id you want to start with.
sparse_set_init :: proc(
	sparse_set: ^SparseSet($T),
	max_id: u32,
	dense_cap: u32,
	allocator: runtime.Allocator = context.allocator,
) {
	// len starts at 1 for a sentinel index
	sparse_set^ = SparseSet(T) {
		dense  = make([dynamic]T, 1, dense_cap, allocator),
		sparse = make([dynamic]u32, max_id, allocator),
		id     = make([dynamic]Id, 1, allocator),
	}
}

soa_set_init :: proc(
	sparse_set: ^SoaSet($T),
	max_id: u32,
	dense_cap: u32,
	allocator: runtime.Allocator = context.allocator,
) {
	// len starts at 1 for a sentinel index
	sparse_set^ = SoaSet(T) {
		dense  = make(#soa[dynamic]T, 1, dense_cap, allocator),
		sparse = make([dynamic]u32, max_id, allocator),
		id     = make([dynamic]Id, 1, allocator),
	}
}

sparse_set_get_ptr :: proc(sparse_set: ^SparseSet($T), id: Id) -> (slot: ^T, is_ok: bool) {
	idx := sparse_set.sparse[id]
	if idx == 0 do return
	return &sparse_set.dense[idx], true
}

sparse_set_try_insert :: proc(
	sparse_set: ^SparseSet($T),
	id: Id,
	data: T,
) -> (
	slot: ^T,
	is_ok: bool,
) {
	assert(id > INVALID_INDEX)
	if len(sparse_set.sparse) <= int(id) {
		resize(&sparse_set.sparse, int(id) + 1)
	}
	index := len(sparse_set.dense)
	sparse_set.sparse[id] = u32(index)
	append(&sparse_set.dense, data)
	append(&sparse_set.id, id)
	slot = &sparse_set.dense[index]
	return slot, slot != nil
}

sparse_set_remove :: proc(sparse_set: ^SparseSet($T), removed_id: Id) {
	assert(removed_id > INVALID_INDEX)

	removed_index := sparse_set.sparse[removed_id]
	if (removed_index == INVALID_INDEX) do return // safely exits if entity has no data
	len := len(sparse_set.dense)
	assert(len > 1, "sparse_set array is empty!")

	last_index := u32(len - 1)

	if (removed_index != last_index) {
		// swap sparse id index lookup if not last
		// because the unordered remove will change the dense
		// index for the last id
		last_id := sparse_set.id[last_index]
		sparse_set.sparse[last_id] = removed_index
	}

	sparse_set.sparse[removed_id] = 0
	unordered_remove(&sparse_set.dense, removed_index)
	unordered_remove(&sparse_set.id, removed_index)
}

sparse_set_array_to_iter :: proc(sparse_set: ^SparseSet($T)) -> SparseSetIter(T) {
	// ignore sentinel
	return {index = 1, data = sparse_set.dense[:]}
}

sparse_set_iterator :: proc(it: ^SparseSetIter($T)) -> (val: DenseSlot(T), idx: int, cond: bool) {
	cond = it.index < len(it.data)

	for ; cond; cond = it.index < len(it.data) {
		val = it.data[it.index]
		idx = it.index
		it.index += 1
	}

	return
}

soa_set_get :: proc(
	soa_set: ^SoaSet($T),
	id: Id,
) -> (
	dense: ^#soa[dynamic]T,
	index: u32,
	ok: bool,
) {
	index = soa_set.sparse[u32(id)]
	ok = index > 0
	if (ok) do dense = &soa_set.dense
	return
}

soa_set_index :: proc(soa_set: ^SoaSet($T), id: Id) -> (index: u32, ok: bool) {
	index = soa_set.sparse[u32(id)]
	ok = index > 0
	return
}

soa_set_insert :: proc(soa_set: ^SoaSet($T), id: Id, data: T) {
	assert(id > INVALID_INDEX)
	if id := int(id); len(soa_set.sparse) <= id {
		resize(&soa_set.sparse, id + 1)
	}
	index := len(soa_set.dense)
	soa_set.sparse[id] = u32(index)
	append(&soa_set.dense, data)
	append(&soa_set.id, id)
}

soa_set_remove :: proc(soa_set: ^SoaSet($T), removed_id: Id) {
	assert(removed_id > INVALID_INDEX)
	removed_index := soa_set.sparse[removed_id]
	len := len(soa_set.dense)
	assert(len > 1, "sparse_set array is empty!")
	last_index := u32(len - 1)

	if (removed_index != last_index) {
		// swap sparse id index lookup if not last
		// because the unordered remove will change the dense
		// index for the last id
		last_id := soa_set.id[last_index]
		soa_set.sparse[last_id] = removed_index
	}
	soa_set.sparse[removed_id] = 0
	unordered_remove_soa(&soa_set.dense, removed_index)
	unordered_remove(&soa_set.sparse, removed_index)
}
