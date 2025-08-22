# /etc/qubes/policy.d/30-audio-camera.policy
/etc/qubes/policy.d/30-audio-camera.policy:
  file.managed:
    - mode: '0644'
    - contents: |
        # Only specific VMs may request audio/camera; everything else deny+notify
        # Audio example: allow work & personal, deny others
        qubes.AudioPlayback  work      sys-audio  allow
        qubes.AudioPlayback  personal  sys-audio  allow
        qubes.AudioPlayback +allow-all-names       +allow-all-names         deny notify=yes

        qubes.VideoInput    +allow-all-names        sys-camera  ask
        qubes.VideoInput    +allow-all-names            +allow-all-names     deny notify=yes

        # Never Allow audio input; allway ask for video input
        qubes.AudioInput    +allow-all-names        sys-audio  ask notify=yes
        qubes.AudioInput    +allow-all-names            +allow-all-names     deny notify=yes
