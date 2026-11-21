#include "ss2k_protocol.h"
#include "ss2k_secure.h"
#include "CustomCharacteristicProtocol.h"
#include <assert.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
  uint8_t bytes[1024], out[1024];
  size_t n, written;
  ss2k_packet view;
  int64_t value;
  ss2k_result result;
  if (argc > 2) {
    size_t i;
    n = strlen(argv[2]) / 2;
    assert(n <= sizeof(bytes) && strlen(argv[2]) % 2 == 0);
    for (i = 0; i < n; ++i) { char hex[3] = {argv[2][2*i], argv[2][2*i+1], 0}; bytes[i] = (uint8_t)strtoul(hex, NULL, 16); }
    if (strcmp(argv[1], "request") == 0) {
      result = ss2k_validate_request(bytes,n);
      if (result == SS2K_OK) {
        assert(ss2k_encode_request(bytes[0],bytes[1],bytes+2,n-2,out,sizeof(out),&written) == SS2K_OK);
        assert(written == n && memcmp(bytes,out,n) == 0);
      }
    } else {
      ss2k_reply_kind kind = strcmp(argv[1],"read") == 0 ? SS2K_REPLY_READ : strcmp(argv[1],"write") == 0 ? SS2K_REPLY_WRITE : SS2K_NOTIFICATION;
      result = ss2k_decode_response(bytes,n,kind,0,&view);
      if (result == SS2K_OK || result == SS2K_REMOTE_ERROR) {
        assert(view.status == bytes[0]);
        assert(ss2k_encode_response(view.status,bytes[1],kind,bytes+2,n-2,out,sizeof(out),&written) == SS2K_OK);
        assert(written == n && memcmp(bytes,out,n) == 0);
      }
    }
    printf("%s", result == SS2K_OK || result == SS2K_REMOTE_ERROR ? "valid" : "invalid");
    if (result == SS2K_REMOTE_ERROR) printf(" error");
    else if (strcmp(argv[1],"request") != 0 && result == SS2K_OK && ss2k_decode_scalar(&view,&value)==SS2K_OK) printf(" %" PRId64,value);
    puts(""); return 0;
  }
  {
    ss2k_fragment_state state = {0,0};
    uint8_t head[] = {0xf0,1,0,0xd0,1}, tail[] = {0xf0,2,1,2};
    uint8_t nested[] = {0xf0,3,0,0xf0};
    const uint8_t *record;
    assert(ss2k_secure_accept(&state,bytes,3,head,sizeof(head),&record,&n)==SS2K_FRAME_PENDING);
    assert(ss2k_secure_accept(&state,bytes,3,tail,sizeof(tail),&record,&n)==SS2K_FRAME_COMPLETE);
    assert(n==3 && record==bytes && record[0]==0xd0 && record[2]==2);
    assert(ss2k_secure_accept(&state,bytes,3,tail,sizeof(tail),&record,&n)==SS2K_FRAME_INVALID);
    assert(ss2k_secure_accept(&state,bytes,2,head,sizeof(head),&record,&n)==SS2K_FRAME_PENDING);
    assert(ss2k_secure_accept(&state,bytes,2,tail,sizeof(tail),&record,&n)==SS2K_FRAME_INVALID);
    assert(ss2k_secure_accept(&state,bytes,2,nested,sizeof(nested),&record,&n)==SS2K_FRAME_INVALID);
    assert(ss2k_secure_accept(&state,NULL,0,head+3,2,&record,&n)==SS2K_FRAME_COMPLETE && record==head+3 && n==2);
  }
  {
    uint8_t chunk[7 + SS2K_DIRCON_OTA_CHUNK_BYTES + 1] = {0x02, 0x38, 0x01, 0x00, 0x04};
    size_t length = sizeof(chunk) - 1;
    assert(length + SS2K_SECURE_OVERHEAD == SS2K_DIRCON_OTA_MAX_WIRE);
    assert(ss2k_validate_request(chunk, SS2K_SECURE_MAX_INNER) == SS2K_OK);
    assert(ss2k_validate_request(chunk, SS2K_SECURE_MAX_INNER + 1) == SS2K_INVALID);
    assert(ss2k_validate_dircon_ota_chunk(chunk, length) == SS2K_OK);
    assert(ss2k_validate_dircon_ota_chunk(chunk, length + 1) == SS2K_INVALID);
    assert(ss2k_validate_dircon_ota_chunk(chunk, 8) == SS2K_OK);
    assert(ss2k_validate_dircon_ota_chunk(chunk, 7) == SS2K_INVALID);
    assert(ss2k_validate_dircon_ota_chunk(NULL, length) == SS2K_INVALID);
    chunk[2] = SS2K_OTA_FINISH;
    assert(ss2k_validate_dircon_ota_chunk(chunk, length) == SS2K_INVALID);
    chunk[2] = SS2K_OTA_CHUNK;
    chunk[0] = SS2K_READ;
    assert(ss2k_validate_dircon_ota_chunk(chunk, length) == SS2K_INVALID);
    chunk[0] = SS2K_WRITE;
    chunk[1] = 0x07;
    assert(ss2k_validate_dircon_ota_chunk(chunk, length) == SS2K_INVALID);
  }
  assert(ss2k_find(0x33)==NULL && ss2k_find(0)==NULL && ss2k_find(255)==NULL);
  assert(customCharacteristicValueFormat(BLE_hMin)==CustomSigned32);
  assert(customCharacteristicValueFormat(0x33)==CustomUnknown);
  switch (BLE_hMin) { case BLE_hMin: break; default: assert(0); }
  assert(ss2k_encode_scalar_write(0x06,263,out,sizeof(out),&written)==SS2K_OK);
  assert(written==4 && memcmp(out,"\x02\x06\x07\x01",4)==0);
  memset(out,0xa5,sizeof(out));
  assert(ss2k_encode_scalar_write(0x06,263,out,3,&written)==SS2K_BUFFER_TOO_SMALL && written==0 && out[0]==0xa5);
  assert(ss2k_encode_scalar_write(0x06,-1,out,sizeof(out),&written)==SS2K_INVALID && written==0);
  assert(ss2k_encode_scalar_write(0x02,-32769,out,sizeof(out),&written)==SS2K_INVALID);
  assert(ss2k_encode_scalar_write(0x19,INT64_C(2147483648),out,sizeof(out),&written)==SS2K_INVALID);
  assert(ss2k_encode_request(SS2K_WRITE,0x07,NULL,1,out,sizeof(out),&written)==SS2K_INVALID);
  assert(ss2k_encode_request(SS2K_READ,0x07,NULL,0,NULL,2,&written)==SS2K_INVALID);
  assert(ss2k_validate_request(NULL,0)==SS2K_INVALID);
  assert(ss2k_decode_response(NULL,0,SS2K_REPLY_READ,0,&view)==SS2K_INVALID);
  memcpy(bytes,"\x80\x0a\x01\x00",4);
  assert(ss2k_decode_response(bytes,4,SS2K_REPLY_WRITE,1,&view)==SS2K_OK && view.payload_length==1);
  assert(ss2k_decode_response(bytes,4,SS2K_REPLY_READ,1,&view)==SS2K_INVALID);
  assert(ss2k_decode_response(bytes,4,(ss2k_reply_kind)99,1,&view)==SS2K_INVALID);
  assert(ss2k_encode_response(SS2K_SECURE_NOTIFICATION,0x35,SS2K_REPLY_READ,bytes,2,out,sizeof(out),&written)==SS2K_INVALID && written==0);
  assert(ss2k_encode_response(SS2K_SECURE_NOTIFICATION,0x35,SS2K_REPLY_WRITE,bytes,2,out,sizeof(out),&written)==SS2K_INVALID && written==0);
  /* All raw scalar boundaries round-trip through the actual compiled codec. */
  {
    unsigned id;
    for (id=1;id<=255;++id) {
      const ss2k_descriptor *d=ss2k_find((uint8_t)id);
      int64_t min=0,max=0,v;
      if(!d) continue;
      switch(d->write_request) {
        case SS2K_FORMAT_BOOL: max=1; break;
        case SS2K_FORMAT_U16: max=65535; break;
        case SS2K_FORMAT_I16: min=-32768;max=32767;break;
        case SS2K_FORMAT_I32: min=INT32_MIN;max=INT32_MAX;break;
        default: continue;
      }
      for(v=min;;v=max) {
        assert(ss2k_encode_scalar_write((uint8_t)id,v,bytes,sizeof(bytes),&n)==SS2K_OK);
        bytes[0]=SS2K_SUCCESS;
        assert(ss2k_decode_response(bytes,n,SS2K_REPLY_WRITE,0,&view)==SS2K_OK);
        assert(ss2k_decode_scalar(&view,&value)==SS2K_OK && value==v);
        if(v==max) break;
      }
    }
  }
  printf("C99 checks passed; descriptors: %zu bytes, heap: 0.\n",sizeof(ss2k_descriptor)*SS2K_COMMAND_COUNT);
  return 0;
}
