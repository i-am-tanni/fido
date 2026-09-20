package game

import "../shared"
import "base:runtime"
import "core:container/queue"
import "core:fmt"
import "core:nbio"
import "core:slice"
import "core:sync/chan"

// Shared types
Ref :: shared.Ref
ConnRef :: shared.ConnRef
Id :: shared.Id
BLOCK_IN_SIZE :: shared.BLOCK_IN_SIZE
BLOCK_OUT_SIZE :: shared.BLOCK_OUT_SIZE
NetworkEvent :: shared.NetworkEvent
UserOutput :: shared.UserOutput
NetworkEventType :: shared.NetworkEventType

MAX_DIR_VAL :: int(max(Direction))
MAX_ENTITY_ID :: 24

g_mem: ^GameMem

//
// Channels
//
input_channel: chan.Chan(NetworkEvent)
// channel for obtaining recycled input blocks that back NetworkEvents
blocks_in: chan.Chan(^[BLOCK_IN_SIZE]byte)
// channel for obtaining recycled output blocks that back UserOutput
blocks_out: chan.Chan(^[BLOCK_OUT_SIZE]byte)
output_channel: chan.Chan(UserOutput)

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

// a player controlled entity
Player :: struct {
	conn_ref: ConnRef,
}

GameMem :: struct {
	entity:    SparseSet(Entity),
	hierarchy: SparseSet(Hierarchy),
	parent:    [dynamic]Ref,
	show:      SparseSet(Show),
	health:    SparseSet(Health),
	exit:      SparseSet(Exitable),
	player:    SparseSet(Player),
	// list of available ids for recycling
	free_list: queue.Queue(Id),
}

Room :: struct {
	name:  string,
	short: string,
	long:  string,
	id:    Id,
}

Recipient :: struct {
	conn_ref: ConnRef,
	game_ref: Ref,
}

@(export)
game_init :: proc(channels: shared.Channels) {
	g_mem = new(GameMem)
	input_channel = channels.input_channel
	output_channel = channels.output_channel
	blocks_in = channels.blocks_in
	blocks_out = channels.blocks_out

	// Prepare
	sparse_set_init(&g_mem.entity, max_id = MAX_ENTITY_ID, dense_cap = MAX_ENTITY_ID)
	sparse_set_init(&g_mem.hierarchy, max_id = MAX_ENTITY_ID, dense_cap = MAX_ENTITY_ID)
	sparse_set_init(&g_mem.show, max_id = MAX_ENTITY_ID, dense_cap = MAX_ENTITY_ID)
	sparse_set_init(&g_mem.exit, max_id = MAX_ENTITY_ID, dense_cap = MAX_ENTITY_ID)
	sparse_set_init(&g_mem.player, max_id = MAX_ENTITY_ID, dense_cap = MAX_ENTITY_ID)
	g_mem.parent = make([dynamic]Ref, MAX_ENTITY_ID, MAX_ENTITY_ID)

	// hierarchy has a special init step b/c we want to avoid using nulls for now
	sentinel := &g_mem.hierarchy.dense[0]

	sentinel^ = Hierarchy {
		first_kid = sentinel,
		next_sib  = sentinel,
		prev_sib  = sentinel,
	}

	// Populate
	ref1 := room_new(
		g_mem,
		Room{name = "North Room", long = "It's warm up here.", short = "", id = 1},
	)
	ref2 := room_new(
		g_mem,
		Room{name = "South Room", long = "It's cold down here.", short = "", id = 2},
	)
	exit_add(&g_mem.exit, ref1.id, ExitData{to_ref = ref2, direction = .Dir_South})
	exit_add(&g_mem.exit, ref2.id, ExitData{to_ref = ref1, direction = .Dir_North})
}

@(export)
game_update :: proc() -> bool {
	for {
		event, event_ok := chan.try_recv(input_channel)
		if !event_ok {
			break
		}

		switch event.type {
		case .Command:
			parsed, ok := parse_command(event.payload)
			_dispatch_ok := dispatch_cmd(g_mem, event, parsed)
			nbio.wake_up(event.loop)

		case .Connect:
			fmt.println("Connected!")
			// get game ref and communicate that to the network thread
			ref := player_new(g_mem, Player{conn_ref = event.conn_ref})
			// update game ref
			update_game_ref(event.conn_ref, ref)
			event.game_ref = ref
			// move to room 1
			child_prepend(g_mem, Ref{1, 0}, ref)
			do_look(g_mem, event)
			nbio.wake_up(event.loop)


		case .Disconnect:
			fmt.println("Disconnected!")
			entity_rmv_soft(g_mem, event.game_ref)
		}


		// return block to be reused if one was used
		if event.block != nil {
			chan.send(blocks_in, event.block)
		}
	}

	free_all(context.temp_allocator)
	return true
}

@(export)
game_shutdown :: proc() {
	free(g_mem)
}

@(export)
game_memory :: proc() -> rawptr {
	return g_mem
}

@(export)
game_hot_reloaded :: proc(mem: ^GameMem, channels: shared.Channels) {
	g_mem = mem
	input_channel = channels.input_channel
	output_channel = channels.output_channel
	blocks_in = channels.blocks_in
	blocks_out = channels.blocks_out
}

// Output to one recipient
output1 :: proc(str: string, conn_ref: ConnRef) {
	len := len(str)
	bytes := 0
	// stuff into the string into multiple blocks
	for pos := 0; pos < len; pos += bytes {
		block, ok := chan.recv(blocks_out)
		assert(ok, "Output block could not be retrieved from return channel!")
		bytes = min(len - pos, BLOCK_OUT_SIZE)
		copy(block[:bytes], str[pos:pos + bytes])
		chan.send(
			output_channel,
			UserOutput {
				num_recipients = 1,
				msg = string(block[:bytes]),
				game_ref = Ref{},
				conn_ref = conn_ref,
				block = block,
			},
		)
	}
}

// Output to one recipient with a ref
output1_via_ref :: proc(g_mem: ^GameMem, ref: Ref, str: string) -> bool {
	id := deref(g_mem, ref) or_return
	player := sparse_set_get_ptr(&g_mem.player, id) or_return
	output1(str, player.conn_ref)
	return true
}

// send to multiple recipients
// used for shared blocks
// e.g. the same message is broadcasted for all recipients
output_n :: proc(str: string, refs: []ConnRef) {
	// number of reads required for the shared block
	num_recipients := len(refs)
	len := len(str)
	bytes := 0
	// stuff into the string into multiple blocks
	for pos := 0; pos < len; pos += bytes {
		// shared block, which is read counted by the network thread
		// to determine when to recycle
		block, ok := chan.recv(blocks_out)
		assert(ok, "Output block could not be retrieved from return channel!")
		bytes = min(len - pos, BLOCK_OUT_SIZE)
		dummy_ref := Ref{}
		copy(block[:bytes], str[pos:pos + bytes])
		for conn_ref in refs {
			chan.send(
				output_channel,
				UserOutput {
					num_recipients = u8(num_recipients),
					msg            = string(block[:bytes]),
					// only update_game_ref requires a verified game_ref
					game_ref       = dummy_ref,
					conn_ref       = conn_ref,
					block          = block,
				},
			)
		}
	}
}

// given a ref, return a valid id or fail
deref :: proc(state: ^GameMem, ref: Ref) -> (id: Id, is_valid: bool) {
	if ref.id == 0 do return
	entity := sparse_set_get_ptr(&state.entity, ref.id) or_return
	return ref.id, ref == entity.ref
}

entity_new_assign_id :: proc(g_mem: ^GameMem) -> Ref {
	id, ok := queue.pop_front_safe(&g_mem.free_list)
	if !(ok) {
		id = Id(len(g_mem.entity.dense))
	}
	return entity_new(g_mem, id)
}

entity_new :: proc(g_mem: ^GameMem, id: Id) -> Ref {
	entity := Entity {
		ref = Ref{id = id},
	}
	ptr, is_ok := sparse_set_try_insert(&g_mem.entity, id, entity)

	// if insertion fails because there already is data there
	if (!is_ok) {
		idx := g_mem.entity.sparse[id]
		ptr := &g_mem.entity.dense[idx]
		ptr.ref.generation += 1
	}

	return ptr.ref
}

entity_rmv_soft :: proc(g_mem: ^GameMem, ref: Ref) -> bool {
	id := deref(g_mem, ref) or_return
	entity, _ := sparse_set_get_ptr(&g_mem.entity, id)
	entity.ref.generation += 1
	queue.push_back(&g_mem.free_list, ref.id)
	for prop in entity.property_set {
		prop_rmv(g_mem, ref, prop)
	}
	return true
}

entity_rmv_hard :: proc(g_mem: ^GameMem, ref: Ref) -> bool {
	id := deref(g_mem, ref) or_return
	entity, _ := sparse_set_get_ptr(&g_mem.entity, id)
	for prop in entity.property_set {
		prop_rmv(g_mem, ref, prop)
	}
	sparse_set_remove(&g_mem.entity, ref.id)
	queue.push_back(&g_mem.free_list, ref.id)
	for prop in entity.property_set {
		prop_rmv(g_mem, ref, prop)
	}
	return true
}

has_property :: #force_inline proc(g_mem: ^GameMem, property: Property, id: Id) -> bool {
	entity, _ := sparse_set_get_ptr(&g_mem.entity, id)
	return property in entity.property_set
}

prop_add :: proc(g_mem: ^GameMem, ref: Ref, data: PropertyData) -> bool {
	id := deref(g_mem, ref) or_return
	property := data_to_property(data)
	if has_property(g_mem, property, id) do return false
	switch val in data {
	case Hierarchy:
		sparse_set_try_insert(&g_mem.hierarchy, id, val)
	case Show:
		sparse_set_try_insert(&g_mem.show, id, val)
	case Health:
		sparse_set_try_insert(&g_mem.health, id, val)
	case Exitable:
		sparse_set_try_insert(&g_mem.exit, id, val)
	case Player:
		sparse_set_try_insert(&g_mem.player, id, val)
	}

	slot, ok := sparse_set_get_ptr(&g_mem.entity, id)
	if !ok do return false
	slot.property_set |= {property}
	return true
}

prop_rmv :: proc(g_mem: ^GameMem, ref: Ref, property: Property) -> bool {
	id := deref(g_mem, ref) or_return
	if !has_property(g_mem, property, id) do return false

	switch property {
	case .Hierarchy:
		child_prop_rmv(g_mem, id)
	case .Show:
		sparse_set_remove(&g_mem.show, id)
	case .Health:
		sparse_set_remove(&g_mem.health, id)
	case .Exitable:
		sparse_set_remove(&g_mem.exit, id)
	case .Player:
		sparse_set_remove(&g_mem.player, id)
	case .None: // do nothing
	}
	slot, ok := sparse_set_get_ptr(&g_mem.entity, id)
	if !ok do return false
	slot.property_set |= {property}

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

hierarchy_init :: proc(g_mem: GameMem, hierarchy: ^Hierarchy) {
	sentinel := &g_mem.hierarchy.dense[0]
	hierarchy^ = {
		first_kid = sentinel,
		next_sib  = sentinel,
		prev_sib  = sentinel,
	}
}

child_move :: proc(g_mem: ^GameMem, child_ref: Ref, to_parent: Ref) -> bool {
	id := deref(g_mem, child_ref) or_return
	child_rmv(g_mem, id) or_return
	child_prepend(g_mem, to_parent, child_ref) or_return
	return true
}

child_prop_rmv :: proc(g_mem: ^GameMem, id: Id) -> bool {
	ok := child_rmv(g_mem, id)
	g_mem.parent[id] = {}
	sparse_set_remove(&g_mem.hierarchy, id)
	return ok
}

child_rmv :: proc(g_mem: ^GameMem, id: Id) -> bool {
	child := sparse_set_get_ptr(&g_mem.hierarchy, id) or_return
	parent_id, _ := deref(g_mem, g_mem.parent[id])
	parent, _ := sparse_set_get_ptr(&g_mem.hierarchy, parent_id)

	sentinel := &g_mem.hierarchy.dense[0]
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
child_prepend :: proc(g_mem: ^GameMem, parent_ref: Ref, child_ref: Ref) -> bool {
	// you can't contain yourself!
	if parent_ref == child_ref do return false

	parent_id := deref(g_mem, parent_ref) or_return
	child_id := deref(g_mem, child_ref) or_return
	child := sparse_set_get_ptr(&g_mem.hierarchy, child_id) or_return
	parent := sparse_set_get_ptr(&g_mem.hierarchy, parent_id) or_return

	head := parent.first_kid
	sentinel := &g_mem.hierarchy.dense[0]

	is_empty := head == sentinel

	child.next_sib = is_empty ? child : head
	child.prev_sib = is_empty ? child : head.prev_sib
	child.prev_sib.next_sib = child
	child.next_sib.prev_sib = child
	parent.first_kid = child
	g_mem.parent[child_id] = parent_ref
	return true
}

// Insert child as the last kid of the parent
//
child_append :: proc(g_mem: ^GameMem, parent_ref: Ref, child_ref: Ref) -> bool {
	// you can't contain yourself!
	if parent_ref == child_ref do return false

	parent_id := deref(g_mem, parent_ref) or_return
	child_id := deref(g_mem, child_ref) or_return

	child := sparse_set_get_ptr(&g_mem.hierarchy, child_id) or_return
	parent := sparse_set_get_ptr(&g_mem.hierarchy, parent_id) or_return

	sentinel := &g_mem.hierarchy.dense[0]
	head := parent.first_kid

	is_empty := head == sentinel
	child.next_sib = is_empty ? child : head
	child.prev_sib = is_empty ? child : head.prev_sib
	child.next_sib.prev_sib = child
	child.prev_sib.next_sib = child

	parent.first_kid = is_empty ? child : head
	g_mem.parent[child_id] = parent_ref

	return true
}

exit_add :: proc(sparse_set: ^SparseSet(Exitable), id: Id, exit_data: ExitData) -> bool {
	if exit_data.direction == .Dir_None do return false
	data, ok := sparse_set_get_ptr(sparse_set, id)
	// if exit property does not exist for this id
	if !ok {
		new := Exitable{}
		append(&new.exit_list_sorted, ExitData{})
		sparse_set_try_insert(sparse_set, id, new)
		data, ok = sparse_set_get_ptr(sparse_set, id)
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

is_player :: proc(g_mem: GameMem, id: Id) -> bool {
	if int(id) >= len(g_mem.player.sparse) do return false
	return g_mem.player.sparse[id] > 0
}

room_new :: proc(g_mem: ^GameMem, room: Room) -> Ref {
	ref := entity_new(g_mem, room.id)
	hierarchy := Hierarchy{}
	hierarchy_init(g_mem^, &hierarchy)
	hierarchy.ref = ref
	exits := Exitable{}
	append(&exits.exit_list_sorted, ExitData{})
	prop_add(g_mem, ref, hierarchy)
	prop_add(g_mem, ref, Show{room.name, room.short, room.long})
	prop_add(g_mem, ref, exits)
	return ref
}

player_new :: proc(g_mem: ^GameMem, data: Player) -> Ref {
	ref := entity_new_assign_id(g_mem)
	hierarchy := Hierarchy{}
	hierarchy_init(g_mem^, &hierarchy)
	hierarchy.ref = ref
	prop_add(g_mem, ref, hierarchy)
	prop_add(g_mem, ref, data)
	prop_add(g_mem, ref, Show{short = "A player is here.", long = "", name = "Player"})
	return ref
}

update_game_ref :: #force_inline proc(conn_ref: ConnRef, game_ref: Ref) {
	chan.send(output_channel, UserOutput{conn_ref = conn_ref, game_ref = game_ref})
}
