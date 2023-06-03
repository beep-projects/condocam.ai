# Copyright (c) 2021-2023, The beep-projects contributors
# this file originated from https://github.com/beep-projects
# Do not remove the lines above.
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see https://www.gnu.org/licenses/

# import the necessary packages
import numpy as np
import argparse
import cv2
import time
import imutils
from imutils import paths

# construct the argument parser and parse the arguments
ap = argparse.ArgumentParser()
#ap.add_argument("-i", "--image", required=True, help="path to the input image")
ap.add_argument("-f", "--folder", required=True, help="path to images directory")
#ap.add_argument('-p', '--prototxt', required=True, help='path to Caffe deploy prototxt file')
##ap.add_argument('-m', '--model', required=True, help='path to the Caffe pre-trained model')
ap.add_argument("-c", "--confidence", type=float, default=0.2,
                                      help="minimum probability to filter weak detections")
args = vars(ap.parse_args())

PROTOTXT="MobileNetSSD_deploy.prototxt.txt"
CAFFEEMODEL="MobileNetSSD_deploy.caffemodel"
#PROTOTXT="MobileNetSSDV2_4_deploy.prototxt.txt"
#CAFFEEMODEL="MobileNetSSDV2_4_deploy_50000.caffemodel"

# initialize the list of class labels MobileNet SSD was trained to
# detect, then generate a set of bounding box colors for each class
CLASSES = ["background", "aeroplane", "bicycle", "bird", "boat",
           "bottle", "bus", "car", "cat", "chair", "cow", "diningtable",
           "dog", "horse", "motorbike", "person", "pottedplant", "sheep",
           "sofa", "train", "tvmonitor"]

#CLASSES = ('background',
#           'person'
#           # ,'face'
#            ,'car',
#            'bicycle'
#           )

#CLASSES = (  # always index 0
#    'aeroplane', 'bicycle', 'bird', 'boat',
#    'bottle', 'bus', 'car', 'cat', 'chair',
#    'cow', 'diningtable', 'dog', 'horse',
#    'motorbike', 'person', 'pottedplant',
#    'sheep', 'sofa', 'train', 'tvmonitor')

#CLASSES = ('person bicycle', 'car', 'motorcycle', 'airplane', 'bus', 'train', 'truck',
#           'boat', 'traffic', 'light', 'fire', 'hydrant', 'stop', 'sign', 'parking',
#           'meter', 'bench', 'bird', 'cat', 'dog', 'horse', 'sheep', 'cow', 'elephant',
#           'bear', 'zebra', 'giraffe', 'backpack', 'umbrella', 'handbag', 'tie', 'suitcase',
#           'frisbee', 'skis', 'snowboard', 'sports', 'ball', 'kite', 'baseball', 'bat',
#           'baseball', 'glove', 'skateboard', 'surfboard', 'tennis', 'racket', 'bottle',
#           'wine', 'glass', 'cup', 'fork', 'knife', 'spoon', 'bowl', 'banana', 'apple',
#           'sandwich', 'orange', 'broccoli', 'carrot', 'hot', 'dog', 'pizza', 'donut',
#           'cake', 'chair', 'couch', 'potted', 'plant', 'bed', 'dining', 'table', 'toilet',
#           'tv', 'laptop', 'mouse', 'remote', 'keyboard', 'cell', 'phone', 'microwave', 'oven',
#           'toaster', 'sink', 'refrigerator', 'book', 'clock', 'vase', 'scissors', 'teddy',
#           'bear', 'hair', 'drier', 'toothbrush')

COLORS = np.random.uniform(0, 255, size=(len(CLASSES), 3))

# load our serialized model from disk
print("[INFO] loading model...")
net = cv2.dnn.readNetFromCaffe(PROTOTXT, CAFFEEMODEL)

# load the input image and construct an input blob for the image
# by resizing to a fixed 300x300 pixels and then normalizing it
# (note: normalization is done via the authors of the MobileNet SSD
# implementation)
# loop over the image paths
for imagePath in paths.list_images(args["folder"]):
  #image = cv2.imread(args['image'])
  image = cv2.imread(imagePath)
  (h, w) = image.shape[:2]
  #blob = cv2.dnn.blobFromImage(cv2.resize(image, (300, 300)), 0.007843, (300, 300), 127.5)
  #detection is most accurate on original image, but to slow
  #blob = cv2.dnn.blobFromImage(image, 0.007843, (w, h), 127.5)
  #resize image for faster processing
  scale_percent = 100 # percent of original size
  width = int(image.shape[1] * scale_percent / 100)
  height = int(image.shape[0] * scale_percent / 100)

  image2 = imutils.resize(image, width=min(480, image.shape[1]))

  start_time = time.time()
  #blob = cv2.dnn.blobFromImage(cv2.resize(image, (width, height), interpolation = cv2.INTER_AREA),
  #                             0.007843, (width, height), 127.5)
  blob = cv2.dnn.blobFromImage(image2, 0.007843, (image2.shape[1], image2.shape[0]), 127.5)

  # pass the blob through the neural network
  print("[INFO] computing object detection...")
  net.setInput(blob)
  detections = net.forward()
  print("--- detection duration %s seconds ---" % (time.time() - start_time))
  # loop over the detections
  for i in np.arange(0, detections.shape[2]):
    # extract the confidence (i.e., the probability) associated with the prediction
    confidence = detections[0, 0, i, 2]

    # filter out weak detections by ensuring the 'confidence' is greater than the minimum confidence
    if confidence > args["confidence"]:
      # extract the index of the classes label from the 'detections',
      # then compute the (x, y)-coordinates of the bounding box for the object
      idx = int(detections[0, 0, i, 1])
      #if CLASSES[idx] == "person":
      if True:
        box = detections[0, 0, i, 3:7] * np.array([w, h, w, h])
        (startX, startY, endX, endY) = box.astype("int")

        # display the prediction
        label = "{}: {:.2f}%".format(CLASSES[idx], confidence * 100)
        print("[INFO] {}".format(label))
        cv2.rectangle(image, (startX, startY), (endX, endY), COLORS[idx], 2)
        y = startY - 15 if startY - 15 > 15 else startY + 15
        cv2.putText(image, label, (startX, y), cv2.FONT_HERSHEY_SIMPLEX, 0.5, COLORS[idx], 2)

        # show the output image
        cv2.imshow("Output", image)
        cv2.waitKey(0)
