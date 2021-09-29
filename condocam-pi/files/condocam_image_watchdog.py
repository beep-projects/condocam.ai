# Copyright (c) 2021, The beep-projects contributors
# this file originated from https://github.com/beep-projects
# Do not remove the lines above.
# The rest of this source code is subject to the terms of the Mozilla Public License.
# You can obtain a copy of the MPL at <https://www.mozilla.org/MPL/2.0/>.
"""Watchdog for an image folder to trigger people detection on save images.

The watchdog checks one folder for creation of jpeg files.
If a new jpeg file is created, the watchdog triggers the obeject detection
via MobileNetSSD DNN. If the object detection identifies persons, the
image is sent via telegram-notify.
"""

import numpy
import argparse
import cv2
import imutils
import time
import queue
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
import filetype
from multiprocessing import Pool
import sys
import multiprocessing
import subprocess


class ImageDirectoryWatcher:  # pylint: disable=too-few-public-methods
  """Watchdog for a specified image directory.

  The watchdog checks one folder for creation of jpeg files, via a JPEGHandler
  and hands the image paths over to processImage

  Attributes:
  dirToWatch: Path to the image directory that should be watched
  imagequeue: queue used for communication of created jpeg files to processImage
  """

  def __init__(self, dirToWatch, imagequeue):
    """Inits the watchdog."""
    self._dir_to_watch = dirToWatch
    self._image_queue = imagequeue
    self.observer = Observer()

  def run(self):
    """Creates the JPEGHandler for reacting on the creation of jpegs in the folder."""
    event_handler = JPEGHandler(self._image_queue)
    self.observer.schedule(event_handler, self._dir_to_watch, recursive=True)
    self.observer.start()
    try:
      while True:
        time.sleep(1)
    except:  # pylint: disable=bare-except
      e = sys.exc_info()[0]  # pylint: disable=invalid-name
      print("Error: " + e)
      self.observer.stop()
      self.observer.join()


class JPEGHandler(FileSystemEventHandler):
  """Class for putting newly created jpegs into a managed queue
  for further processing by other functions."""

  def __init__(self, imagequeue):
    """Inits the JPEGHandler.

    Attributes:
      imagequeue: queue used for passing newly created jpeg files
                  to processImage for further processing
    """
    self._image_queue = imagequeue

  def on_created(self, event):
    """function for handling file creation events.

    Attributes:
      event: the actual create event that should be checked for further processing
    """
    if event.is_directory:
      return
    # If a file is created check if it is a jpeg image
    # for jpg images the check often fails, also
    # when using imghdr.what(). Therefor we rely on the file extension for these
    if filetype.is_image(event.src_path) is not None or event.src_path.lower().endswith(
        (".jpg", ".jpeg")):
      # if it is an image, put it into the processing queue
      self._image_queue.put(event.src_path)


def process_image(image_queue, confidence):
  """Inits the JPEGHandler.

  Attributes:
    image_queue: queue used for passing newly created jpeg files to process_image.
      The queue is checked regularily for new images. Once a new image is detected,
      it is put through the cv2.dnn MobileNetSSD for object detection
      if a person is detected in the image, that image is sent out via telegram
    confidence: the minimum required confidence for accepting a detected person
      from the MobileNetSSD classification. Only if the confidence is higher
      than the given value, an alert will be triggert
  """
  prototxt = "MobileNetSSD_deploy.prototxt.txt"
  caffeemodel = "MobileNetSSD_deploy.caffemodel"
  blob_size = 480
  # initialize the list of class labels MobileNet SSD was trained to detect
  classes = [
      "background", "aeroplane", "bicycle", "bird", "boat", "bottle", "bus", "car", "cat", "chair",
      "cow", "diningtable", "dog", "horse", "motorbike", "person", "pottedplant", "sheep", "sofa",
      "train", "tvmonitor"
  ]
  # load our serialized model from disk
  net = cv2.dnn.readNetFromCaffe(prototxt, caffeemodel)
  while True:
    #check if there is an image in the queue and process it
    try:
      image_path = image_queue.get()
    except queue.Empty:
      time.sleep(1)  #wait a while and continue with the next iteration
      continue
    # load the input image and construct an input blob for the image
    # by resizing to fit the blob_size and then normalizing it
    # (note: normalization is done via the authors of the MobileNet SSD
    # implementation)
    image = cv2.imread(image_path)
    image2 = None
    if image.shape[0] > image.shape[1]:
      image2 = imutils.resize(image, height=min(blob_size, image.shape[0]))
    else:
      image2 = imutils.resize(image, width=min(blob_size, image.shape[1]))
    blob = cv2.dnn.blobFromImage(image2, 0.007843, (image2.shape[1], image2.shape[0]), 127.5)
    net.setInput(blob)
    detections = net.forward()

    person_detected = False
    # loop over the detections
    for i in numpy.arange(0, detections.shape[2]):
      # extract the confidence (i.e., the probability) associated with the prediction
      prediction_confidence = detections[0, 0, i, 2]

      # filter out weak detections by ensuring the
      # "prediction_confidence" is greater than the minimum confidence
      if prediction_confidence > confidence:
        # extract the index of the classes label from the "detections",
        idx = int(detections[0, 0, i, 1])
        if classes[idx] == "person":
          person_detected = True
          #one person in the image is enough
          break

    if person_detected:
      #print("person detected in ", image_path)
      subprocess.run(["telegram", "--quiet", "--photo", image_path], check=False)


def main():
  """main function, starts the image directory watchdog, the image processing process pool
    and sets up the queue used for communication between these modules"""
  # construct the argument parser and parse the arguments
  ap = argparse.ArgumentParser()
  ap.add_argument(
      "-p", "--path", required=True, help="path to the image folder that should be monitored")
  ap.add_argument(
      "-c",
      "--confidence",
      type=float,
      default=0.5,
      help="minimum probability for people detection, to filter weak detections")
  args = vars(ap.parse_args())
  image_directory = args[
      "path"]  #base path, the watcher will go recursively into the subdirectories
  confidence = args["confidence"]
  #create the queue for communication between file watchdog and processing processes
  image_queue = multiprocessing.Manager().Queue(
  )  #we need a Manager().Queue() for synchronized sharing between processes
  #create and start the file watchdog
  image_directory_watcher = ImageDirectoryWatcher(image_directory, image_queue)
  watchdog = multiprocessing.Process(target=image_directory_watcher.run, args=[])
  watchdog.daemon = True
  watchdog.start()
  # start the image processing threads
  pool_size = multiprocessing.cpu_count()
  if pool_size > 1:
    pool_size -= 1
  # use all available cores except one for the rest of the system
  # this should keep the system responsive if many images are saved at once
  with Pool(pool_size) as pool:
    arguments = []
    for _ in range(pool_size):
      arguments.append((image_queue, confidence))
    pool.starmap(process_image, arguments)


#end of main()

if __name__ == "__main__":
  main()
