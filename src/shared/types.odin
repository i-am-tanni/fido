package types

import "core:nbio"
import "core:sync/chan"

// Backing block sizes for moving bytes to and from the network / game loops
BLOCK_OUT_SIZE :: 512
BLOCK_IN_SIZE :: 1024

Id :: distinct u32

Ref :: struct {
	id:         Id,
	generation: u32,
}

ConnRef :: struct {
	id:  u32,
	gen: u32,
}

NetworkEventType :: enum {
	Connect,
	Disconnect,
	Command,
}

NetworkEvent :: struct {
	loop:     ^nbio.Event_Loop,
	payload:  string,
	// id and generation of the connection
	conn_ref: ConnRef,
	// a signal from the game loop to terminate the connection
	game_ref: Ref,
	type:     NetworkEventType,
	// pointer to backing block to return to the input return channel
	block:    ^[BLOCK_IN_SIZE]byte,
}

UserOutput :: struct {
	id:             u64,
	// id and generation of the connection
	conn_ref:       ConnRef,
	// id and generation of the entity / instance of this character in game
	game_ref:       Ref,
	// a signal from the game loop to terminate the connection
	is_terminating: bool,
	// the payload from the server to the socket
	msg:            string,
	// pointer to backing block to return to the output return channel
	block:          ^[BLOCK_OUT_SIZE]byte,
}

Channels :: struct {
	input_channel:  chan.Chan(NetworkEvent),
	// channel for obtaining recycled input blocks that back NetworkEvents
	blocks_in:      chan.Chan(^[BLOCK_IN_SIZE]byte),
	// channel for obtaining recycled output blocks that back UserOutput
	blocks_out:     chan.Chan(^[BLOCK_OUT_SIZE]byte),
	output_channel: chan.Chan(UserOutput),
}
