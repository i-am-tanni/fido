package game

import "../shared"
import "base:runtime"
import "core:c/libc"
import "core:container/queue"
import "core:dynlib"
import "core:fmt"
import "core:nbio"
import "core:os"
import "core:sync/chan"
import "core:thread"
import "core:time"

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
			text, text_ok := dispatch_cmd(g_mem, event.game_ref, parsed)
			output(text, event.game_ref, event.conn_ref)
			nbio.wake_up(event.loop)

		case .Connect:
			fmt.println("Connected!")
			// get game ref
			ref := player_new(g_mem, Player{conn_ref = event.conn_ref})

			// move to room 1
			child_prepend(g_mem, Ref{1, 0}, ref)

			text, ok := do_look(g_mem, ref)
			output(text, ref, event.conn_ref)
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


// stuff the output channel
output :: proc(str: string, game_ref: Ref, conn_ref: ConnRef) {
	len := len(str)
	bytes := 0
	// stuff into the string into 256 byte blocks
	for pos := 0; pos < len; pos += bytes {
		block, ok := chan.recv(blocks_out)
		assert(ok, "Output block could not be retrieved from return channel!")
		bytes = min(len - pos, BLOCK_OUT_SIZE)
		copy(block[:bytes], str[pos:pos + bytes])
		chan.send(
			output_channel,
			UserOutput {
				id = 32,
				msg = string(block[:bytes]),
				game_ref = game_ref,
				conn_ref = conn_ref,
				block = block,
			},
		)
	}
}
