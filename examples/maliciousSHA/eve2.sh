#�@	��M�Ӽ�Ip�ox&��7+��Pj�KU8�̭�F��Q~E6�~⊟�U��z��

if [ `od -t x1 -j3 -N1 -An "${0}"` -eq "91" ]; then 
  echo "Cryptol";
else
  echo "Galois";
fi
