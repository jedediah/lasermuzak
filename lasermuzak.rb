#!/usr/bin/env ruby



###############################################################
# These are the parameters for your CNC machine, which you set.
# You may also have to fiddle with the settings for your
# machine to get a nice sound out of it. Try increasing the
# "maximum acceleration" a lot.

# Which axes do you want to play muzak with?
  AXES = [:x,:y,:w]

# Dots Per Inch of your stepper motors, or whatever you have
  DPI = {:x => 500.0, :y => 500.0, :w => 2000.0}

# Boundaries of your machine
  BOUNDS = {:x => 0.5..23.0, :y => 0.5..17.5, :w => -1.0..0.0}

# That's the end of things you set (unless you're brave).
# Now, the magic begins!
###############################################################



class Hash
  def map_pairs &block
    r = {}
    each_pair {|k,v| r[k] = block[k,v] }
    r
  end

  def map_pairs! &block
    each_pair {|k,v| self[k] = block[k,v] }
  end
end

class Array
  def map_hash &block
    r = {}
    each{|k| r[k] = block[k]}
    r
  end
end

def vector_sum(a,b)
  b.merge(a).map_pairs{|k,v| (a[k] || 0) + (b[k] || 0) }
end

# note length to minutes given tempo and dynamics
def length_to_minutes(length,tempo,dynamics)
  dynamics * 4 / length / tempo
end

SEMITONE = 2.0**(1.0/12.0)  # frequency ratio of one semitone up

# note (0-11) and octave to Hz
def pitch_to_freq(note,octave)
  440.0 * SEMITONE**(octave*12 + note - 45)
end

SCALE = {                   # valid notes that can appear in the muzak
  "c"  => 0.0,
  "c#" => 1.0,
  "d"  => 2.0,
  "d#" => 3.0,
  "e"  => 4.0,
  "f"  => 5.0,
  "f#" => 6.0,
  "g"  => 7.0,
  "g#" => 8.0,
  "a"  => 9.0,
  "a#" => 10.0,
  "b"  => 11.0
} 

$tempo = 120.to_r            # quarter notes per minute
$length = 4.to_r             # logical note length in 1/whole notes
$octave = 4.0                # logical octave, c-4 is middle c
$dynamics = 1.to_r           # actual note duration relative to logical length
$axis = AXES[0]              # current axis while reading muzak
$minutes = Hash.new 0.to_r   # time index in minutes for each axis while reading muzak

# list of note on/off events, built in arbitrary order and later sorted
# each event means: at :minutes, set :axis to :frequency (which can be zero)
$events = []

# append an event with given frequency and duration
def add_event freq, minutes, score=nil
  $events << {
    :minutes => $minutes[$axis],  # absolute time index in minutes
    :axis => $axis,               # axis
    :freq => freq,                # frequency in Hz
    :score => score               # musical score for this event
  }

  $minutes[$axis] += minutes
end

def note p, l, s
  l = (l && l.to_r) || $length
  s = (s && DYN[s]) || $dynamics

  add_event pitch_to_freq(SCALE[p],$octave),      # frequency
            length_to_minutes(l,$tempo,s),        # duration (minutes)
            "#{$axis}: #{p}#{$octave} l#{l} s#{s}"
  
  add_event 0.0, length_to_minutes(l,$tempo,1-s)  # note off
end

def rest l
  l = (l && l.to_r) || $length
  add_event 0.0,
            length_to_minutes(l,$tempo,1.to_r),
            "#{$axis}: .#{l}"
end

DYN = {"!" => 0.5.to_r, "-" => 1.to_r}

GRAMMAR = {
  /^#.*/ => lambda { },                                 # comment
  /^([a-g]#?)([\d\/]+)?(!|-)?/ => method(:note),        # note
  /^o(\d+)/ => lambda {|o| $octave = o.to_i },          # absolute octave
  /^>/ => lambda { $octave += 1 },                      # octave up
  /^</ => lambda { $octave -= 1 },                      # octave down
  /^l([\d\/]+)/ => lambda {|l| $length = l.to_r },      # note length
  /^\.([\d\/]+)?/ => method(:rest),                     # rest
  /^t([\d]+)/ => lambda {|t| $tempo = t.to_r },         # tempo
  /^s([\d\/]+)/ => lambda {|s| $dynamics = s.to_r },    # dynamics
  /^:([A-Za-z])/ => lambda {|a| $axis = a.to_sym }      # change axis
}

File.open ARGV[0] do |muzak|
  line_number = 1

  muzak.each_line do |line|
    line.sub!(/#.*/,"")
    line.downcase!
    line.lstrip!

    while form = GRAMMAR.find {|form, rule| line =~ form}
      line = $'.lstrip     # chop form and trailing whitespace from beginning of line
      form[1][*$~[1..-1]]  # call lambda associated with form and pass sub-matches as arguments
    end

    raise "line #{line_number} parse error at '#{line[0..10]}'" unless line.empty?
    line_number += 1
  end
end



### CNC Stuff ###

MIDPOINT = BOUNDS.map_pairs{|x,r| r.first+(r.last-r.first)/2 }

# Hz to inches/minute at given dpi
def freq_to_feed(freq,dpi)
  60.0 * freq.to_f / dpi.to_f
end

# resultant feed rate given zero or more axes moving simultaneously at independent feed rates
def combined_feed v
  Math.sqrt(v.reduce(0) {|a,x| a + x[1]**2 })
end

# takes a vector of frequencies for zero or more axes and a duration in minutes
# returns [delta_motion, feed_rate]
# if all frequencies are zero, so will be feed_rate
def music_to_movement freq, minutes
  feed = freq.map_pairs{|x,f| freq_to_feed(f,DPI[x]) }
  [feed.map_pairs{|x,f| f*minutes }, combined_feed(feed)]
end

def movement_to_gcode pos, feed=nil
  return "" if pos.empty?
    
  if feed
    "G1 F#{feed}"
  else
    "G0"
  end + (pos.map{|x,p| " #{x.to_s.upcase}#{p}" }.join) + "\n"
end

# given current position, axis frequencies and duration, return gcode
# position is updated destructively
def music_to_gcode! pos, freq, minutes
  if freq.all? {|x,f| f.to_f == 0.0 }
    # G4 (dwell) for silence
    "G4 P%f\n" % (minutes*60)
  else
    # G1 for one or more tones
    motion, feed = music_to_movement(freq, minutes)

    pos.map_pairs! do |x,p|
      unless BOUNDS[x] === p + motion[x]*$dir[x]
        # reverse direction when axis hits the edge
        $dir[x] *= -1
      end

      p + motion[x]*$dir[x]
    end

    movement_to_gcode(pos, feed)
  end
end

$pos = BOUNDS.map_pairs{|x,r| r.first }   # current position of each axis
$dir = AXES.map_hash {|k| 1 }
$freq = AXES.map_hash { 0 }               # current frequency of each axis
$minutes = 0.0
$score = []

# sort events by time
$events.sort! do |a,b|
  if a[:minutes] == b[:minutes]
    # make sure note on happens *after* simultaneous note off
    a[:freq] <=> b[:freq]
  else
    a[:minutes] <=> b[:minutes]
  end
end

# jog to midpoint
print movement_to_gcode($pos)
puts "G4 P1"

$events.each do |ev|
  # puts "(#{ev[:minutes].floor}:#{"%06.3f" % (ev[:minutes]*60%60)} #{ev[:axis]}=#{ev[:freq]})"

  if ev[:minutes] > $minutes && ev[:freq] != $freq[ev[:axis]]
    # event is later than the current eventset and changes the frequency of an axis

    # put the score for the current moment in a comment
    puts "(#{$score.join ' '})" unless $score.empty?
    $score.clear

    # generate gcode motion from last eventset frequencies and
    # time delta between last eventset and this event
    # this call updates position destructively
    print music_to_gcode!($pos, $freq, ev[:minutes] - $minutes)

    # update time
    $minutes = ev[:minutes]
  end

  # update running frequency and score
  $freq[ev[:axis]] = ev[:freq]
  $score << ev[:score] if ev[:score]
end

puts "M2"
