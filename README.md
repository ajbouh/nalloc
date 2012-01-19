nalloc
===========

A simple tool for allocating nodes.

Author
------

Original author: adamb

Contributors:

* The Nalloc Authors

Fusion support
--------------
Clusters allocated using the Fusion driver require both a vmx template and a
vmdk. The vmx file provides a template configuration for each node in the
cluster, while the vmdk provides the base disk image.

**Vmdk Requirements**

The base OS in the vmdk must have a root password and VMware tools installed.
It is used for out-of-band access to each node before networking has
been configured.

**Vmx Template Requirements**

See the sample template provided by nalloc in
```templates/fusion/zygote.vmx.erb```.

**Setup**

Run ```rake fusion:setup```. You'll probably want to enter at least the vmdk
path.

**Teardown**

Run ```rake fusion:teardown```. This will remove all traces of nalloc Fusion
support from your system.

**Node options for nalloc-init**

Required:

* root_pass - The root password for the node
* username  - Name of the initial user
* ssh_key_name - Private key name (or path to private key). The corresponding
                 public key will be added to the authorized_keys file for
                 username.

Optional:

* vmdk_path - Path to base vmdk to use. Note that the default vmdk specified
              during setup will be used if none is provided.
* vmx_template - Path to vmx_template. This will default to either the template
                 specified during setup or the template provided with nalloc.

License
-------

(The MIT License)

Copyright (c) 2011 The Nalloc Authors

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
'Software'), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
