# Fido

There was a lack of MUD server examples in Odin on github and since I got this working, I wanted to share it.

This is an experimental server in Odin using non-blocking IO (nbio) and separate threads for the network and the simulation itself.

The goal of this project is to explore architecture for text-based multiplayer games.

## Overview

The game loop ticks every 100ms. At the start of the tick, all network events queued in the input channel are drained and processed.
After that, game simulation logic runs and finally any outputs are deep copied to the output channel queue. Then the network loop is woken up to process.

In terms of memory strategy, a frame allocator is used for all temporary allocations needed during a pulse then cleared for the next.
For network events, a set of pre-allocated backing blocks is used for all binary data crossing thread boundaries.
The network thread requests a backing block from the return channel when it's ready to send an input event.
It copies the command into the block and sends it to the input channel to be read by the game loop when it wakes up.
Output uses backing blocks in a similar fashion when crossing thread boundaries.

## Project Status (Disclaimer)

⚠️ **Please Note:** This project is incomplete and **very early stages** of development.

## Main Features

- Non blocking IO on the network thread
- Hot reloading of all game code that runs in the game thread
- Game state is semi-ECS where components (called properties here) are represented as sparse sets
- Containers and room contents are represented as something like a left kid right sib (LCRS) tree backed by an array.


## What's been added?

- Basic comms: channels of various topics via a pubsub system, says in a room
- Basic navigation from room to room via exits

## About Me

I'm a hobbyist that got into programming muds in the early 00s.

