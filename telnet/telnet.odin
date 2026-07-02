package telnet

// Telnet commands
TELNET_IAC :: 255
TELNET_DONT :: 254
TELNET_DO :: 253
TELNET_WONT :: 252
TELNET_WILL :: 251
TELNET_SB :: 250
TELNET_SE :: 240
TELNET_EOR :: 239

Telnet :: struct($T: typeid) {
	// Connection data
	user_data: T,
	// event handler
	ev:        proc(user_data: T, event: Event),
	// State machine state
	state:     Telnet_State,
	// the following three fields are for subnegotiations
	// buffer pos
	buf_pos:   int,
	sb_telopt: byte,
	// buffer for subnegotiated data
	buf:       []byte,
}

Telnet_Command :: enum {
	Telnet_Cmd_Do,
	Telnet_Cmd_Dont,
	Telnet_Cmd_Will,
	Telnet_Cmd_Wont,
}

Telnet_State :: enum {
	Telnet_State_Data,
	Telnet_State_Eol,
	Telnet_State_Iac,
	Telnet_State_Do,
	Telnet_State_Dont,
	Telnet_State_Will,
	Telnet_State_Wont,
	Telnet_State_Sb,
	Telnet_State_Sb_Data,
	Telnet_State_Sb_Iac,
}

Telnet_Ev_Text :: struct {
	data: []byte,
}

Telnet_Ev_Negotiate :: struct {
	cmd:    Telnet_Command,
	telopt: u8,
}

Telnet_Ev_Subnegotiate :: struct {
	telopt: u8,
	data:   []byte,
}

Telnet_Ev_IAC :: distinct byte

// Events sent to the event handler when receiving a byte stream as input
Event :: union #no_nil {
	// Text is not guaranteed to be sent as a full line
	Telnet_Ev_Text,
	Telnet_Ev_Negotiate,
	Telnet_Ev_Subnegotiate,
	Telnet_Ev_IAC,
}

init :: proc(telnet: ^Telnet($T), buf: []byte, ev: proc(user_data: T, event: Event)) {
	telnet.ev = ev
	telnet.buf = buf
}

process :: proc(telnet: ^Telnet($T), stream: []byte) {
	start := 0
	for x, i in stream {
		switch telnet.state {
		// default in-band data
		case Telnet_State_Data:
			if x == TELNET_IAC {
				// if there is any, transmit text when encountering an IAC
				if (i > start) {
					text := Telnet_Ev_Text(stream[start:i - start])
					telnet.eh(telnet.ud, text)
					telnet.state = Telnet_State_Iac
				}
			}

			if byte == '\r' {
				if (i > start) {
					text := Telnet_Ev_Text(stream[start:i - start])
					telnet.eh(telnet.ud, text)
				}
				telnet.state = Telnet_State_Eol
			}

		// the rest of the cases are out-of-band (OOB) data
		case Telnet_State_Iac:
			switch x {
			// Can you please do
			case TELNET_DO:
				telnet.state = Telnet_State_Do
			// Can you please not do
			case TELNET_DONT:
				telnet.state = Telnet_State_Dont
			// Want to
			case TELNET_WILL:
				telnet.state = Telnet_State_Will
			// Do not want to
			case TELNET_WONT:
				telnet.state = Telnet_State_Wont
			case TELNET_SB:
				telnet.state = Telnet_State_Sb
			case TELNET_IAC:
				// byte escaping
				telnet.ev(
					telnet.ud,
					Telnet_Ev_Text(newline_count = telnet.newline_count, data = TELNET_IAC[:]),
				)
				start += 1
				telnet.state = Telnet_State_Data

			case _:
				telnet.ev(telnet.ud, Telnet_Ev_Iac(x))
				start += 1
				telnet.state = Telnet_State_Data
			}

		case Telnet_State_Do:
			telnet.ev(telnet, Negotiate{Telnet_Cmd_Do, x})
			telnet.state = Telnet_State_Data

		case Telnet_State_Dont:
			telnet.ev(telnet, Negotiate{Telnet_Cmd_Dont, x})
			telnet.state = Telnet_State_Data

		case Telnet_State_Will:
			telnet.ev(telnet, Negotiate{Telnet_Cmd_Will, x})
			telnet.state = Telnet_State_Data

		case Telnet_State_Wont:
			telnet.ev(telnet, Negotiate{Telnet_Cmd_Wont, x})
			telnet.state = Telnet_State_Data

		// subnegotiation begin
		case Telnet_State_Sb:
			telnet.sb_telopt = x
			telnet.buf_pos = 0
			telnet.state = Telnet_State_Sb_Data

		case Telnet_State_Sb_Data:
			if x == TELNET_IAC {
				telnet.state = Telnet_State_Sb_Iac
			}

			if !try_buffer_byte(telnet, x) {
				telnet.state = Telnet_State_Data
			}

		case Telnet_State_Sb_Iac:
			switch (x) {
			case TELNET_SE:
				if telnet.sb_telopt != 0 {
					telnet.ev(
						telnet.ud,
						Subnegotiate(telnet.sb_telopt, telnet.buffer[:telnet.buf_pos]),
					)
					telnet.state = Telnet_State_Data
				}

			// unexpected byte encountered!
			case _:
				start = i + 1
				telnet.state = Telnet_State_Iac
				process(telnet, x[:])
			}

		case Telnet_State_Eol:
			// only \r\n and \r\0 are valid.
			// if \r\n is received, only send \n
			// if \r\0 is received, only send \r
			// if \r and another byte is received. Send \r and the byte and let
			// caller deal with it
			if x != '\n' {
				telnet.ev(telnet.ud, Telnet_Ev_Text('\r'))
			}

			start = i
			if x == '\x00' {
				start += 1
			}
			telnet->state = Telnet_State_Data
		}

		// send any remaining bytes
		if (i > start) {
			telnet.eh(telnet.ud, Telnet_Ev_Text(data = stream[start:i - start]))
			telnet.state = Telnet_State_Iac
		}
	}
}

@(private = "file")
try_buffer_byte :: proc(telnet: ^Telnet, byte: byte) -> bool {
	if telnet.buf_pos < len(telnet.buf) {
		telent.buf[telnet.buf_pos] = byte
		telnet.buf_pos += 1
		return true
	}

	return false
}
