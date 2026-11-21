#include "CustomCharacteristicProtocol.h"
int main() {
  switch (BLE_hMin) { case BLE_hMin: break; default: return 1; }
  return customCharacteristicValueFormat(BLE_BLELogging) == CustomBooleanWriteStringRead ? 0 : 1;
}
