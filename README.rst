========
busbcopy
========

Simple BASH script to automate copying files/images to a large number of USB
sticks.

We used this to populate 100s of USB sticks for the conference proceedings of
PLDI 2014.

Usage
-----

.. code::

	Usage: busbcopy.sh [<options>] <command> [<args>]

	Commands available:
		enum       Enumerate all valid USB storage devices.
		copy       Copy to a single target.
		verify     Verify all attached USB storage devices against source image.
		batchcopy  Batch copy to all USB storage devices attached to this system.

	Options:
		--source
			Source image or directory with files to copy to targets.
		--verify
			When copying an image, automatically verify.
		--eject
			Use 'eject' when done with copying.

.. rubric:: Example usage

1. Create "gold" image on a target USB storage device (which is assumed to be
   the same as all the remaining targets).

2. ``$> dd if=/dev/<to-gold-device> of=source.img`` (ideally, the size is
   constrained via ``count=``, but requires knowing how the storage device is
   partitioned)

3. Remove ``/dev/<to-gold-device>`` and prepare remaining USB storage devices.

4. Attach as many blank USB storage devices as possible.

5. ``$> busbcopy.sh --source source.img batchcopy``

6. Follow instructions.

For additional assurances, automatically verify (it is likely some USB sticks
might be faulty) and let the script know how many USB storage devices should be
done at once; we had the issue of sometimes a USB stick not appearing, but
still thinking it was done as we didn't count the detected devices (in case of
failure, simply restart the script):

.. code::

    $> busbcopy.sh --source source.img --verify batchcopy 10

Acknowledgements
----------------

Thanks to Cheng-Chieh Huang for feedback.
