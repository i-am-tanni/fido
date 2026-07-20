package fido

import "base:runtime"
import "core:container/queue"
import "core:container/xar"
import "core:fmt"
import "core:nbio"
import "core:sync/chan"
import "core:thread"
import "core:time"
import "lib/telnet"

GAME_TICK_RATE :: time.Millisecond * 100
MAX_CONNECTIONS :: 255
// Leaky Bucket rate limiting constants in bytes
BUCKET_CAP :: 4096
BUCKET_DRAIN_RATE :: 200

Server :: struct {
	socket:          nbio.TCP_Socket,
	// Pool is used for stable pointers
	connection_pool: xar.Array(Connection, 4),
	connections:     [dynamic]^Connection,
	free_list:       queue.Queue(^Connection),
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

NetworkEvent :: struct {
	loop:       ^nbio.Event_Loop,
	connection: ^Connection,
	payload:    string,
	gen:        u32,
	type:       NetworkEventType,
	// pointer to backing block to return to the return channel
	block:      ^[1024]byte,
}

UserOutput :: struct {
	// generation is a guard to make sure output is for this socket
	gen:            u32,
	connection:     ^Connection,
	is_terminating: bool,
	msg:            []byte,
}

//
// Channels
//
input_channel: chan.Chan(NetworkEvent)
// channel for obtaining recycled input blocks that back NetworkEvents
return_channel: chan.Chan(^[1024]byte)
output_channel: chan.Chan(UserOutput)

main :: proc() {
	err: runtime.Allocator_Error
	input_channel, err = chan.create(chan.Chan(NetworkEvent), 1024, context.allocator)
	fmt.assertf(err == nil, "Could not initialize nbio: %v", err)
	defer chan.destroy(input_channel)

	return_channel, err = chan.create(chan.Chan(^[1024]byte), 1024, context.allocator)
	fmt.assertf(err == nil, "Could not initialize nbio: %v", err)
	defer chan.destroy(return_channel)

	output_channel, err = chan.create(chan.Chan(UserOutput), 1024, context.allocator)
	fmt.assertf(err == nil, "Could not initialize nbio: %v", err)
	defer chan.destroy(output_channel)

	thread.create_and_start(network_thread_proc)
	thread.create_and_start(game_thread_proc)

	// after set up, sleep effectively forever
	time.sleep(time.Duration(max(i64)))
}

game_thread_proc :: proc() {
	fmt.println("Game Thread Started")
	for {
		start := time.now()
		event, ok := chan.try_recv(input_channel)

		if ok {
			switch event.type {
			case .Command:
				chan.send(
					output_channel,
					UserOutput {
						connection = event.connection,
						gen = event.gen,
						msg = transmute([]byte)(event.payload[:]),
					},
				)
				// wake up the network thread so that output is processed right away
				nbio.wake_up(event.loop)

			case .Connect:
				fmt.println("Connected!")

			case .Disconnect:
				fmt.println("Disconnected!")
			}

			if event.block != nil {
				// return block to be reused
				chan.send(return_channel, event.block)
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

	// fill return channel with all available blocks
	for &block in blocks {
		chan.send(return_channel, &block)
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
			// Ensure the output belongs to this socket...
			if output.gen != output.connection.gen do continue
			// ..and that the socket is not terminated or terminating..
			if output.connection.is_terminated do continue
			if output.is_terminating {
				close(output.connection)
				continue
			}
			nbio.send_poly(output.connection.socket, {output.msg}, output.connection, on_sent)
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
	// try the freed connections queue first.
	connection, ok := queue.pop_front_safe(&server.free_list)
	// .. and if that fails, get one from the xar connection pool
	if !ok {
		alloc_err: runtime.Allocator_Error
		connection, alloc_err = xar.push_back_elem_and_get_ptr(
			&server.connection_pool,
			Connection{},
		)
		assert(alloc_err == nil)
	}

	connection^ = Connection {
		id     = u8(len(&server.connections)),
		gen    = connection.gen,
		server = server,
		socket = op.accept.client,
	}

	telnet.init(&connection.telnet_data, connection, connection.buf[:], telnet_recv)

	append(&server.connections, connection)
	chan.send(input_channel, NetworkEvent{type = .Connect})
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
	queue.push_back(&conn.server.free_list, conn)
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
			block, ok := chan.recv(return_channel)

			if !ok {
				assert(ok, "Block could not be retrieved from return channel!")
				close(conn)
				return false
			}
			bytes_to_copy := min(len(conn.line_buf), len(block))
			copy(block[:bytes_to_copy], conn.line_buf[:bytes_to_copy])
			event := NetworkEvent {
				type       = .Command,
				loop       = conn.server.loop,
				connection = conn,
				gen        = conn.gen,
				payload    = string(block[:bytes_to_copy]),
				block      = block,
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
