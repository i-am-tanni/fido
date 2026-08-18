package fido

import "base:runtime"
import "core:container/queue"
import "core:container/xar"
import "core:fmt"
import "core:nbio"
import "core:strings"
import "core:sync/chan"
import "core:thread"
import "core:time"
import "lib/telnet"

GAME_TICK_RATE :: time.Millisecond * 100
MAX_CONNECTIONS :: 255
// Leaky Bucket rate limiting constants in bytes
BUCKET_CAP :: 4096
BUCKET_DRAIN_RATE :: 200
KB :: 1024

Server :: struct {
	socket:          nbio.TCP_Socket,
	// Pool is used for stable pointers
	connection_pool: xar.Array(Connection, 4),
	connections:     [dynamic]^Connection,
	free_list:       queue.Queue(u8),
	loop:            ^nbio.Event_Loop,
	is_running:      bool,
	// 1MB is set aside to move inputs from the network thread to the main thread.
	// If this 1mb is exhausted it will cause the thread to block until available
	blocks:          ^[1024][1024]byte,
}

Connection :: struct {
	server:        ^Server,
	telnet_data:   telnet.Telnet(^Connection),
	socket:        nbio.TCP_Socket,
	game_ref:      Ref,
	// generation is a guard to make sure output is for this socket
	gen:           u32,
	// Rate limit bucket. Fills with bytes received and drains every tick.
	bucket:        u16,
	id:            u8,
	is_terminated: bool,
	// data streamed in from the socket
	incoming:      [1024]byte,
	line_buf:      [dynamic; 1024]byte,
	// buffer from subnegotiated data
	buf:           [4096]byte,
	outgoing:      [4096]byte,
}

NetworkEventType :: enum {
	Connect,
	Disconnect,
	Command,
}

ConnRef :: struct {
	id:  u32,
	gen: u32,
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
	block:    ^[1024]byte,
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
	block:          ^[256]byte,
}

//
// Channels
//
input_channel: chan.Chan(NetworkEvent)
// channel for obtaining recycled input blocks that back NetworkEvents
blocks_in: chan.Chan(^[1024]byte)
// channel for obtaining recycled output blocks that back UserOutput
blocks_out: chan.Chan(^[256]byte)
output_channel: chan.Chan(UserOutput)

main :: proc() {
	err: runtime.Allocator_Error
	input_channel, err = chan.create(chan.Chan(NetworkEvent), 1024, context.allocator)
	fmt.assertf(err == nil, "Could not initialize input channel: %v", err)
	defer chan.destroy(input_channel)

	blocks_in, err = chan.create(chan.Chan(^[1024]byte), 1024, context.allocator)
	fmt.assertf(err == nil, "Could not initialize return channel: %v", err)
	defer chan.destroy(blocks_in)

	blocks_out, err = chan.create(chan.Chan(^[256]byte), 20_480_000, context.allocator)
	fmt.assertf(err == nil, "Could not initialize return channel: %v", err)
	defer chan.destroy(blocks_in)

	output_channel, err = chan.create(chan.Chan(UserOutput), 1024, context.allocator)
	fmt.assertf(err == nil, "Could not initialize output channel: %v", err)
	defer chan.destroy(output_channel)

	thread.create_and_start(network_thread_proc)
	thread.create_and_start(game_thread_proc)

	// after set up, sleep effectively forever
	time.sleep(time.Duration(max(i64)))
}

game_thread_proc :: proc() {
	fmt.println("Game Thread Started")
	model := new(Model)
	model_init(model)
	blocks := new([80_000][256]byte)
	// fill output block channel with available blocks
	for &block in blocks {
		chan.send(blocks_out, &block)
	}

	for {
		start := time.now()
		for {
			event := chan.try_recv(input_channel) or_break
			free_all(context.temp_allocator)
			switch event.type {
			case .Command:
				parsed, ok := parse_command(event.payload)
				text, text_ok := dispatch_cmd(model, event.game_ref, parsed)
				output(text, event.game_ref, event.conn_ref)
				nbio.wake_up(event.loop)

			case .Connect:
				fmt.println("Connected!")
				// get game ref
				ref := player_new(model, Player{conn_ref = event.conn_ref})

				// move to room 1
				child_prepend(model, Ref{1, 0}, ref)

				text, ok := do_look(model, ref)
				output(text, ref, event.conn_ref)
				nbio.wake_up(event.loop)


			case .Disconnect:
				fmt.println("Disconnected!")
				entity_rmv_soft(model, event.game_ref)
			}


			if event.block != nil {
				// return block to be reused if one was used
				chan.send(blocks_in, event.block)
			}
		}

		// sleep for the remainder of the tick
		if elapsed := time.diff(time.now(), start); elapsed < GAME_TICK_RATE {
			time.sleep(GAME_TICK_RATE - elapsed)
		}
	}
}

network_thread_proc :: proc() {
	fmt.println("IO Thread Started")
	server: Server
	// backing block for network events sent to the game loop
	blocks := new([1024][1024]byte)
	defer free(blocks)

	// fill input channel with all available blocks
	for &block in blocks {
		chan.send(blocks_in, &block)
	}
	lerr := nbio.acquire_thread_event_loop()
	defer nbio.release_thread_event_loop()

	fmt.assertf(lerr == nil, "Could not initialize nbio: %v", lerr)

	socket, listen_err := nbio.listen_tcp({nbio.IP4_Any, 1234})
	fmt.assertf(listen_err == nil, "Error listening on localhost:1234: %v", listen_err)
	server = Server {
		socket     = socket,
		is_running = true,
		blocks     = blocks,
		loop       = nbio.current_thread_event_loop(),
	}
	queue.init(&server.free_list, 16)

	nbio.accept_poly(socket, &server, on_accept)
	last_game_tick := time.now()
	for server.is_running {
		err := nbio.tick(1 * time.Second)
		fmt.assertf(err == nil, "nbio.tick error: %v", err)
		// Step 1: Leaky bucket rate limiting drains for each connection.
		//
		if elapsed := time.since(last_game_tick); elapsed >= GAME_TICK_RATE {
			mult := u16(elapsed / GAME_TICK_RATE)
			for connection in server.connections {
				drain := BUCKET_DRAIN_RATE * mult
				connection.bucket = (connection.bucket > drain) ? connection.bucket - drain : 0
			}
			last_game_tick = time.now()
		}
		// Step 2: For each output ready and able to send to a socket, do so
		//
		for {
			output := chan.try_recv(output_channel) or_break
			connection := xar.get_ptr(&server.connection_pool, output.conn_ref.id)
			if connection == nil do continue
			// Ensure the output belongs to this socket...
			if output.conn_ref.gen != connection.gen do continue
			// ..and that the socket is not terminated already..
			if connection.is_terminated do continue
			if len(output.msg) > 0 {
				nbio.send_poly(
					connection.socket,
					{transmute([]byte)output.msg},
					connection,
					on_sent,
				)
			}
			// if game_ref is empty, update
			if connection.game_ref.id == 0 {
				connection.game_ref = output.game_ref
			}
			if output.is_terminating {
				close(connection)
			}
			if output.block != nil {
				chan.send(blocks_out, output.block)
			}
		}
	}
}

on_accept :: proc(op: ^nbio.Operation, server: ^Server) {
	fmt.assertf(op.accept.err == nil, "Error accepting a connection: %v", op.accept.err)

	if len(server.connections) >= MAX_CONNECTIONS {
		nbio.close(op.accept.client)
		return
	}

	nbio.accept_poly(server.socket, server, on_accept)
	id: u8
	// try the freed connections queue first.
	index, ok := queue.pop_front_safe(&server.free_list)
	connection: ^Connection
	if ok {
		connection = xar.get_ptr(&server.connection_pool, index)
		id = index
	}
	// .. and if that fails, get one from the xar connection pool
	if !ok {
		alloc_err: runtime.Allocator_Error
		id = u8(xar.array_len(server.connection_pool))
		connection, alloc_err = xar.push_back_elem_and_get_ptr(
			&server.connection_pool,
			Connection{},
		)
		assert(alloc_err == nil)
	}

	connection^ = Connection {
		id     = id,
		gen    = connection.gen,
		server = server,
		socket = op.accept.client,
	}

	telnet.init(&connection.telnet_data, connection, connection.buf[:], telnet_recv)

	append(&server.connections, connection)
	connection_event := NetworkEvent {
		type     = .Connect,
		conn_ref = ConnRef{u32(id), connection.gen},
		loop     = server.loop,
		payload  = "",
		game_ref = Ref{},
		block    = nil,
	}
	chan.send(input_channel, connection_event)
	nbio.recv_poly(op.accept.client, {connection.incoming[:]}, connection, on_recv)
}

on_recv :: proc(op: ^nbio.Operation, conn: ^Connection) {
	if conn.is_terminated do return
	bytes_received := op.recv.received
	fmt.assertf(op.recv.err == nil, "Error receiving from client: %v", op.recv.err)

	if bytes_received == 0 {
		close(conn)
		return
	}

	if conn.bucket > BUCKET_CAP {
		fmt.println("Kicking connection for DDOS protection")
		close(conn)
		return
	}

	ok := telnet.process(&conn.telnet_data, conn.incoming[:op.recv.received])
	// On failure for any reason, kick connection
	if !ok {
		close(conn)
		return
	}

	conn.bucket += u16(bytes_received)
	// continue to receive in a loop
	nbio.recv_poly(conn.socket, {conn.incoming[:]}, conn, on_recv)
}

on_sent :: proc(op: ^nbio.Operation, conn: ^Connection) {
	fmt.assertf(op.send.err == nil, "Error sending to client: %v", op.send.err)
	nbio.recv_poly(conn.socket, {conn.incoming[:]}, conn, on_recv)
}

close :: proc(conn: ^Connection) {
	conn.is_terminated = true
	// incrementing gen will guarantee mis-matched output isn't sent to the
	// wrong socket
	conn.gen += 1
	last := conn.server.connections[len(conn.server.connections) - 1]
	// swap and pop
	last.id = conn.id
	unordered_remove(&conn.server.connections, conn.id)
	queue.push_back(&conn.server.free_list, conn.id)
	nbio.close(conn.socket)
}

// Event handler for processed telnet events
telnet_recv :: proc(conn: ^Connection, ev: telnet.Event) -> bool {
	switch val in ev {
	case telnet.Telnet_Ev_Text:
		for x in val.data {
			// if buffer overflow, fail!
			if len(conn.line_buf) > cap(conn.line_buf) {
				return false
			}

			append(&conn.line_buf, x)

			// keeping appending up to newline
			if x != '\n' do continue

			// If byte is eol..
			// get a recycled block from the game thread as a backing block for user
			// input.
			// Block the thread until memory is ready.
			block, ok := chan.recv(blocks_in)

			if !ok {
				assert(ok, "Input block could not be retrieved from return channel!")
				close(conn)
				return false
			}
			bytes_to_copy := min(len(conn.line_buf), len(block))
			copy(block[:bytes_to_copy], conn.line_buf[:bytes_to_copy])
			event := NetworkEvent {
				type = .Command,
				loop = conn.server.loop,
				conn_ref = ConnRef{id = u32(conn.id), gen = conn.gen},
				game_ref = conn.game_ref,
				payload = string(block[:bytes_to_copy]),
				block = block,
			}
			chan.send(input_channel, event)
			clear(&conn.line_buf)
		}


	case telnet.Telnet_Ev_Negotiate:
	case telnet.Telnet_Ev_Subnegotiate:
	case telnet.Telnet_Ev_Iac:
	}

	return true
}

// stuff the output channel
output :: proc(str: string, game_ref: Ref, conn_ref: ConnRef) {
	pos := 0
	len := len(str)
	i := 0
	// stuff into the string into 256 byte blocks
	for pos < len {
		block, ok := chan.recv(blocks_out)
		assert(ok == true, "Output block could not be retrieved from return channel!")
		left := len - pos
		bytes := min(left, 256)
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
		pos += bytes
	}
}
