package fido

import "core:fmt"
import "core:strings"

// Represents the parsed input from a player
Parsed_Input :: struct {
	command: ParsedCommand,
	args:    string, // Everything after the first word (e.g., "sword from chest")
}

ParserState :: enum {
	Parser_State_Command,
}

ParsedCommand :: enum {
	Command_Invalid,
	Command_Look,
	Command_Go_North,
	Command_Go_South,
	Command_Go_East,
	Command_Go_West,
}

// Parses raw text input into a command and an argument string
parse_input :: proc(raw_input: string) -> (parsed: Parsed_Input, ok: bool) {
	// Trim leading/trailing whitespace (newlines, carriage returns, spaces)
	trimmed := strings.trim_space(raw_input)
	if len(trimmed) == 0 do return
	split, err := strings.split_after_n(trimmed, " ", 2, context.temp_allocator)
	if err != nil do return
	cmd := ""
	args := ""
	if len(split) > 0 do cmd = strings.to_lower(split[0], context.temp_allocator)
	parsed_cmd := parse_command(cmd)
	if parsed_cmd == nil do return
	if len(split) > 1 do args = strings.trim_right(strings.trim_space(split[1]), "\r\n")
	return Parsed_Input{command = parsed_cmd, args = args}, true
}

parse_command :: proc(str: string) -> ParsedCommand {
	// first, try parsing single character commands
	if len(str) == 1 {
		switch (str[0]) {
		case 'l':
			return .Command_Look
		case 'n':
			return .Command_Go_North
		case 's':
			return .Command_Go_South
		case 'e':
			return .Command_Go_East
		case 'w':
			return .Command_Go_West
		}
	}

	return .Command_Invalid
}
