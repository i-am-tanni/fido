# Fido

There was a lack of MUD server examples in Odin on github and since I got this working, I wanted to share it.

This is an experimental server in Odin using non-blocking IO (nbio) and separate threads for the network and the simulation itself.

The goal of this project is to explore architecture for text-based multiplayer games.

## Overview

The game loop ticks every 100ms. At the start of the tick, all network events queued in the input channel are drained and processed.
After that, game simulation logic runs and finally any outputs are deep copied to the output channel queue. Then the network loop is woken up to process.

In terms of memory strategy, a memory arena is used for all temporary allocations needed during the tick then cleared for the next.
For network events, a set of pre-allocated backing blocks is used as a buffer for copying each network event and sending it.
The network thread requests a backing block from the return channel when it's ready to send an input event.
It copies the command into the block and sends it to the input channel to be read by the game loop when it wakes up.

## Project Status (Disclaimer)

⚠️ **Please Note:** This project is incomplete and **very early stages** of development.
Currently it serves as an echo server example.

## About Me

I'm a hobbyist that enjoys writing mud servers to learn various languages.
