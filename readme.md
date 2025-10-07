# Learning Wayland and Audio on linux

Final step of this project is just to make a simple game of lights out, but till i get there we display [Metaballs](https://en.wikipedia.org/wiki/Metaballs), then abstract away the platform layers and create the simple game.

following a [shader guide](https://youtu.be/f4s1h2YETNY), actually generated:

![](./output.gif) 

- currently learning audio.

### note to self
```sh
zig build run
zig build audio
zig build p
```

## Notes

Treat everything as files.

### binds:

1. wl_compositor
2. wl_shm (shared memory)
3. xdg_wm_base
4. wl_seat (inputs)

### images?
1. create wl_surface (wl_compositor::create_surface).
2. set the surface to xdg_surface (xdg_wm_base::get_xdg_surface).
3. define xdg top level (xdg_surface::get_toplevel)
4. commit the surface using wl_commit
5. wait xdg_surface::configure event, and respond to it.
6. to answer a xdg configure, we do xdg_surface::ack_configure
7. then commit to wl_surface again.
8. create shared memory file.
9. allocate proper space.
10. create shared memory pool (may need to be resizeable for win management?)
11. allocate proper wl_buffer  (wl_shm_pool::create_buffer)
12. Attach Surface -> mark as Damaged Surface -> Commit Surface -> event loop

When we receive frame_callback_id and WL_CALLBACK_EVENT_DONE, means we're on "vsync", i think. So we can draw to frame.




## Resources

### Wayland

- [Wayland Source](https://wayland.dpldocs.info/source/)
- [Shimizu](https://git.sr.ht/~geemili/shimizu)
- [Wayland Book](https://wayland-book.com/)
- [Wayland Explorer](https://wayland.app/protocols/wayland#wl_surface:event:preferred_buffer_transform)
- [Wayland From Scratch](https://gaultier.github.io/blog/wayland_from_scratch.html)

### Pipewire

- [Pipewire tutorial](https://docs.pipewire.org/page_tutorial1.html)

## Acronyms

| Name |        Description        |
| :--: | :-----------------------: |
| DRM  | Direct Rendering Manager  |
| GBM  | Generic Buffer Management |

## wayland "package"

What comes with wayland

- Wayland.xml
  - All wayland protocols
- Wayland scanner
  - Tool to process wayland protocols and generate code for them
- libwayland
  - Wire protocol for client and server

## Userspace helpers(?)

### libdrm

- c_api for handling the userspace for DRM
- Generally not used by wayland clients

### Mesa

- Vendor-optimized implementation for opengl, vulkan, gbm
- Used by wayland clients

### libinput

- Userspace for evdev
- Wayland compositor enforces special permissions
- Wayland clients needs to get permission, and other information from the
  compositor

### xkbcommon

- Translates scancodes from libinput to actual "keys"

### pixman

- Library for pixel-specific ideas, math, etc

### libwayland

- Handles low level "wire" code
- Provides tool for generating code from wayland protocols (xml files)

## Wayland Protocol

Works by issuing _requests_ and _events_ that act on a _object_. All objects
have an _interface_ that defines operations which are possible and their
_signatures_, (i.e: wl_display interface).

- Wire protocol format (stream of messages)
- Enumerates interfaces
- Creates resources
- Exchanges messages

### Wire Protocol

Stream of 32-bit values enconded with little or big endian, depending on the
host machine

| Primitive | Description                                                                          |
| --------- | ------------------------------------------------------------------------------------ |
| int32     | int                                                                                  |
| uint32    | uint                                                                                 |
| fixed     | 24.8bit float                                                                        |
| object    | 32 bit object ID                                                                     |
| new_id    | 32 bit object ID and allocates the object                                            |
| string    | prefixed with i32 for length(bytes), padded, null terminated, enconding utf8 default |
| array     | prefixed with i32 for length, padded                                                 |
| fd        | 0bit, file descrition transport(?) to the socket (msg exchange)                      |
| enum      | single value (bitmap) enconded into i32                                              |

#### Messages

An event which acts upon an object, is divided into header(64-bit) and argument

##### Header

Composed of 2 words(32-bit), and the msg size also include the header own size.

1. Affected object id
2. Two i16
   1. Msg size
   2. Request opcode (event)

##### Argument

Can be of any size, as long as its well defined within the header.

#### Object id

- New objects can be created by assigning a new_id to the msg
- Object id 0 is null
- Client allocates from [1, EF FF FF FF]
- Server allocates from [FF 00 00 00, FF FF FF FF]

#### Transports

Works over unix domain sockets, carries file description messages(?) to other
processes To find the Unix socket to connect to, most implementations just do
what libwayland does:

- If WAYLAND_SOCKET is set, interpret it as a file descriptor number on which
  the connection is already established, assuming that the parent process
  configured the connection for us.
- If WAYLAND_DISPLAY is set, concat with XDG_RUNTIME_DIR to form the path to the
  Unix socket.
- Assume the socket name is wayland-0 and concat with XDG_RUNTIME_DIR to form
  the path to the Unix socket.
- Give up.

#### Requests and Events

Are messages, requests go from client to server and events go the other way
around. Example of a trade:

##### request to wl_surface

msg => two words (32-bit) -> header, size, request opcode, msg to ask for a rect
on 0, 0 for example.

|    Words     |   Raw    | Translated  |
| :----------: | :------: | :---------: |
|  object_id   | 0000000E |     14      |
| len + opcode | 00180002 |   24 + 02   |
|     body     | 00000000 |    x: 0     |
|     body     | 00000000 |    y: 0     |
|     body     | 000001FF | width: 511  |
|     body     | 000001FF | height: 511 |

##### events from wl_surface

|    Words     |   Raw    |     Translated      |
| :----------: | :------: | :-----------------: |
|  object_id   | 0000000E |         14          |
| len + opcode | 000C0000 |       12 + 0        |
|     body     | 00000005 | acts on object_id 5 |

then dispatches the process internally

#### Interfaces

Contains the definition for _requests_, _events_, _opcodes_, _signatures_

#### High Level Protocol

All valid interfaces are well defined within wayland.xml and other interfaces
are also known within their own _programs_, such as xdg-shell which has their
own interfaces defined within another .xml file. sample:

```xml
<interface name="wl_surface" version="4">
  <request name="damage">
    <arg name="x" type="int" />
    <arg name="y" type="int" />
    <arg name="width" type="int" />
    <arg name="height" type="int" />
  </request>
  <event name="enter">
    <arg name="output" type="object" interface="wl_output" />
  </event>
</interface>
```
