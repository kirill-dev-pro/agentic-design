package agentic_design

// Keys and mouse buttons by the numbers GLFW gives them (vendor:glfw constants.odin), so the
// interface reads input the same way whichever host feeds it: GLFW's callbacks on the
// desktop, the page's events in a browser (which map KeyboardEvent.code to these numbers).
// Only the ones the app uses are listed.

KEY_0 :: 48
KEY_1 :: 49
KEY_2 :: 50
KEY_A :: 65
KEY_APOSTROPHE :: 39
KEY_B :: 66
KEY_BACKSPACE :: 259
KEY_C :: 67
KEY_COMMA :: 44
KEY_D :: 68
KEY_DELETE :: 261
KEY_DOWN :: 264
KEY_E :: 69
KEY_END :: 269
KEY_ENTER :: 257
KEY_EQUAL :: 61
KEY_ESCAPE :: 256
KEY_F :: 70
KEY_G :: 71
KEY_H :: 72
KEY_HOME :: 268
KEY_K :: 75
KEY_KP_ENTER :: 335
KEY_LEFT :: 263
KEY_LEFT_ALT :: 342
KEY_LEFT_BRACKET :: 91
KEY_LEFT_CONTROL :: 341
KEY_LEFT_SHIFT :: 340
KEY_LEFT_SUPER :: 343
KEY_MINUS :: 45
KEY_N :: 78
KEY_O :: 79
KEY_P :: 80
KEY_R :: 82
KEY_RIGHT :: 262
KEY_RIGHT_ALT :: 346
KEY_RIGHT_BRACKET :: 93
KEY_RIGHT_CONTROL :: 345
KEY_RIGHT_SHIFT :: 344
KEY_RIGHT_SUPER :: 347
KEY_S :: 83
KEY_SLASH :: 47
KEY_SPACE :: 32
KEY_T :: 84
KEY_TAB :: 258
KEY_UP :: 265
KEY_V :: 86
KEY_W :: 87
KEY_X :: 88
KEY_Z :: 90
MOUSE_BUTTON_LEFT :: 0
MOUSE_BUTTON_MIDDLE :: 2
MOUSE_BUTTON_RIGHT :: 1
