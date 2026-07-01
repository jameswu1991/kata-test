```
❯ k logs -f kata-hello 
==========================================
🚀 Hello from inside Cloud Hypervisor!
==========================================
My guest microVM kernel is: 6.18.35
==========================================
```

```
# manually pull if cached without tarball
sudo ctr -n k8s.io images pull --local --snapshotter devmapper --platform linux/amd64 docker.io/library/alpine:latest

❯ k logs -f kata-fc-hello
==========================================
🚀 Hello from inside Firecracker!
==========================================
My guest Firecracker microVM kernel is: 6.18.35
==========================================
```
