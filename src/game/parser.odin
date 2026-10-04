package game

import "core:container/queue"
import "core:fmt"
import "core:strings"
import "core:sync/chan"

// Represents the parsed input from a player
Parsed_Input :: struct {
	command: ParsedCommand,
	args:    string, // Everything after the first word (e.g., "sword from chest")
}

ParserState :: enum {
	Parser_State_Command,
}

ParsedCommand :: enum {
	Cmd_Look,
	Cmd_Go_North,
	Cmd_Go_South,
	Cmd_Go_East,
	Cmd_Go_West,
	Cmd_Look_At,
	Cmd_Say,
	Cmd_Chat,
}

process_command :: proc(g_mem: ^GameMem, input: NetworkEvent) -> bool {
	self_id := deref(g_mem, input.game_ref) or_return
	parsed, ok := parse_command(input.payload)
	if !ok {
		buf, err := make([]byte, 256, context.temp_allocator)
		if err != nil do return false
		sb := strings.builder_from_bytes(buf)
		write_string_ln(&sb, "Huh?")
		write_prompt(&sb, g_mem, self_id)
		output1(strings.to_string(sb), input.conn_ref)
		return false
	}
	ev: Event = ---
	switch parsed.command {
	case .Cmd_Look:
		ev = Ev_Look {
			actor = input.game_ref,
			room  = g_mem.parent[self_id],
		}

	case .Cmd_Go_North:
		ev = Ev_Move {
			actor        = input.game_ref,
			exit_keyword = .Dir_North,
		}
	case .Cmd_Go_South:
		ev = Ev_Move {
			actor        = input.game_ref,
			exit_keyword = .Dir_South,
		}
	case .Cmd_Go_East:
		ev = Ev_Move {
			actor        = input.game_ref,
			exit_keyword = .Dir_East,
		}
	case .Cmd_Go_West:
		ev = Ev_Move {
			actor        = input.game_ref,
			exit_keyword = .Dir_West,
		}

	case .Cmd_Say:
		room_id := deref(g_mem, g_mem.parent[self_id]) or_return
		ev = Ev_Say {
			speaker = input.game_ref,
			room    = g_mem.parent[self_id],
			text    = parsed.args,
		}
	case .Cmd_Look_At:
		room_id := deref(g_mem, g_mem.parent[self_id]) or_return
		ev = Ev_Look_At {
			actor    = input.game_ref,
			room     = g_mem.parent[self_id],
			keywords = parsed.args,
		}

	case .Cmd_Chat:
		do_chat(g_mem, input, parsed.args)
	}

	queue.push_back(&g_mem.event_queue, ev)
	assert(input.block != nil)
	chan.send(blocks_in, input.block)
	return true
}

// Parses raw text input into a command and an argument string
parse_command :: proc(raw_input: string) -> (parsed: Parsed_Input, ok: bool) {
	// Trim leading/trailing whitespace (newlines, carriage returns, spaces)
	trimmed := strings.trim_space(raw_input)
	if len(trimmed) == 0 do return
	split, err := strings.split_n(trimmed, " ", 2, context.temp_allocator)
	if err != nil do return
	cmd: string
	args: string
	if len(split) > 0 do cmd = strings.to_lower(split[0], context.temp_allocator)
	parsed_cmd, cmd_ok := str_to_command(cmd)
	if !cmd_ok do return
	if len(split) > 1 do args = strings.trim_right(strings.trim_space(split[1]), "\r\n")
	return Parsed_Input{command = parsed_cmd, args = args}, true
}

str_to_command :: proc(text: string) -> (command: ParsedCommand, ok: bool) {
	// first, try parsing single character commands
	if len(text) == 1 {
		switch (text[0]) {
		case 'l':
			return .Cmd_Look, true
		case 'n':
			return .Cmd_Go_North, true
		case 's':
			return .Cmd_Go_South, true
		case 'e':
			return .Cmd_Go_East, true
		case 'w':
			return .Cmd_Go_West, true
		case 'c':
			return .Cmd_Chat, true
		case:
			return
		}
	}

	switch (text[0]) {
	case 'l':
		if text == "l" || text == "look" {
			return .Cmd_Look_At, true
		}
	case 'c':
		if text == "chat" {
			return .Cmd_Chat, true
		}
	case 's':
		if text == "say" {
			return .Cmd_Say, true
		}
	}

	return
}
