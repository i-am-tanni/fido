package game

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
	Cmd_Look,
	Cmd_Go_North,
	Cmd_Go_South,
	Cmd_Go_East,
	Cmd_Go_West,
	Cmd_Say,
	Cmd_Chat,
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
