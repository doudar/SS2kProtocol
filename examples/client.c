#include "ss2k_protocol.h"
#include <assert.h>

int main(void) {
  uint8_t packet[6];
  size_t length = 0;
  /* 26.3 km/h is 263 raw units. Send these bytes through BLE or DirCon. */
  assert(ss2k_encode_scalar_write(SS2K_ID_SIMULATED_SPEED, 263,
    packet, sizeof(packet), &length) == SS2K_OK);
  assert(length == 4 && packet[0] == 2 && packet[1] == 6 && packet[2] == 7 && packet[3] == 1);
  return 0;
}
