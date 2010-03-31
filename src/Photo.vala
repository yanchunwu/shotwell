/* Copyright 2009 Yorba Foundation
 *
 * This software is licensed under the GNU LGPL (version 2.1 or later).
 * See the COPYING file in this distribution. 
 */

public enum ImportResult {
    SUCCESS,
    FILE_ERROR,
    DECODE_ERROR,
    DATABASE_ERROR,
    USER_ABORT,
    NOT_A_FILE,
    PHOTO_EXISTS,
    UNSUPPORTED_FORMAT,
    NOT_AN_IMAGE,
    DISK_FAILURE,
    DISK_FULL,
    CAMERA_ERROR;
    
    public string to_string() {
        switch (this) {
            case SUCCESS:
                return _("Success");
            
            case FILE_ERROR:
                return _("File error");
            
            case DECODE_ERROR:
                return _("Unable to decode file");
            
            case DATABASE_ERROR:
                return _("Database error");
            
            case USER_ABORT:
                return _("User aborted import");
            
            case NOT_A_FILE:
                return _("Not a file");
            
            case PHOTO_EXISTS:
                return _("File already exists in database");
            
            case UNSUPPORTED_FORMAT:
                return _("Unsupported file format");

            case NOT_AN_IMAGE:
                return _("Not an image file");
            
            case DISK_FAILURE:
                return _("Disk failure");
            
            case DISK_FULL:
                return _("Disk full");
            
            case CAMERA_ERROR:
                return _("Camera error");
            
            default:
                return _("Imported failed (%d)").printf((int) this);
        }
    }
    
    public bool is_abort() {
        switch (this) {
            case ImportResult.DISK_FULL:
            case ImportResult.DISK_FAILURE:
            case ImportResult.USER_ABORT:
                return true;
            
            default:
                return false;
        }
    }
    
    public bool is_nonuser_abort() {
        switch (this) {
            case ImportResult.DISK_FULL:
            case ImportResult.DISK_FAILURE:
                return true;
            
            default:
                return false;
        }
    }
    
    public static ImportResult convert_error(Error err, ImportResult default_result) {
        if (err is FileError) {
            FileError ferr = (FileError) err;
            
            if (ferr is FileError.NOSPC)
                return ImportResult.DISK_FULL;
            else if (ferr is FileError.IO)
                return ImportResult.DISK_FAILURE;
            else if (ferr is FileError.ISDIR)
                return ImportResult.NOT_A_FILE;
            else
                return ImportResult.FILE_ERROR;
        } else if (err is IOError) {
            IOError ioerr = (IOError) err;
            
            if (ioerr is IOError.NO_SPACE)
                return ImportResult.DISK_FULL;
            else if (ioerr is IOError.FAILED)
                return ImportResult.DISK_FAILURE;
            else if (ioerr is IOError.IS_DIRECTORY)
                return ImportResult.NOT_A_FILE;
            else
                return ImportResult.FILE_ERROR;
        } else if (err is GPhotoError) {
            return ImportResult.CAMERA_ERROR;
        }
        
        return default_result;
    }
}

public interface PhotoTransformationState : Object {
}

// TransformablePhoto is an abstract class that allows for applying transformations on-the-fly to a
// particular photo without modifying the backing image file.  The interface allows for
// transformations to be stored persistently elsewhere or in memory until they're commited en
// masse to an image file.
public abstract class TransformablePhoto: PhotoSource {
    private const string[] IMAGE_EXTENSIONS = {
        // raster formats
        "jpg", "jpeg", "jpe",
        "tiff", "tif",
        "png",
        "gif",
        "bmp",
        "ppm", "pgm", "pbm", "pnm",
        
        // THM are JPEG thumbnails produced by some RAW cameras ... want to support the RAW
        // image but not import their thumbnails
        "thm",
        
        // less common
        "tga", "ilbm", "pcx", "ecw", "img", "sid", "cd5", "fits", "pgf",
        
        // vector
        "cgm", "svg", "odg", "eps", "pdf", "swf", "wmf", "emf", "xps",
        
        // 3D
        "pns", "jps", "mpo",
        
        // RAW extensions
        "3fr", "arw", "srf", "sr2", "bay", "crw", "cr2", "cap", "iiq", "eip", "dcs", "dcr", "drf",
        "k25", "kdc", "dng", "erf", "fff", "mef", "mos", "mrw", "nef", "nrw", "orf", "ptx", "pef",
        "pxn", "r3d", "raf", "raw", "rw2", "raw", "rwl", "rwz", "x3f"
    };
    
    // There are assertions in the photo pipeline to verify that the generated (or loaded) pixbuf
    // is scaled properly.  We have to allow for some wobble here because of rounding errors and
    // precision limitations of various subsystems.  Pixel-accuracy would be best, but barring that,
    // need to just make sure the pixbuf is in the ballpark.
    private const int SCALING_FUDGE = 8;
    
    public enum Exception {
        NONE            = 0,
        ORIENTATION     = 1 << 0,
        CROP            = 1 << 1,
        REDEYE          = 1 << 2,
        ADJUST          = 1 << 3,
        ALL             = 0xFFFFFFFF;
        
        public bool prohibits(Exception exception) {
            return ((this & exception) != 0);
        }
        
        public bool allows(Exception exception) {
            return ((this & exception) == 0);
        }
    }
    
    // NOTE: This class should only be instantiated when row is locked.
    private class PhotoTransformationStateImpl : Object, PhotoTransformationState {
        private Orientation orientation;
        private Gee.HashMap<string, KeyValueMap>? transformations;
        private PixelTransformer transformer;
        private PixelTransformationBundle adjustments;
        
        public PhotoTransformationStateImpl(TransformablePhoto photo) {
            orientation = photo.row.orientation;
            transformations = copy_transformations(photo.row.transformations);
            transformer = photo.transformer != null ? photo.transformer.copy() : null;
            adjustments = photo.adjustments != null ? photo.adjustments.copy() : null;
        }
        
        public Orientation get_orientation() {
            return orientation;
        }
        
        public Gee.HashMap<string, KeyValueMap>? get_transformations() {
            return copy_transformations(transformations);
        }
        
        public PixelTransformer? get_transformer() {
            return (transformer != null) ? transformer.copy() : null;
        }
        
        public PixelTransformationBundle? get_color_adjustments() {
            return (adjustments != null) ? adjustments.copy() : null;
        }
        
        private static Gee.HashMap<string, KeyValueMap>? copy_transformations(
            Gee.HashMap<string, KeyValueMap>? original) {
            if (original == null)
                return null;
            
            Gee.HashMap<string, KeyValueMap>? clone = new Gee.HashMap<string, KeyValueMap>();
            foreach (string object in original.keys)
                clone.set(object, original.get(object).copy());
            
            return clone;
        }
    }
    
    // because fetching individual items from the database is high-overhead, store all of
    // the photo row in memory
    private PhotoRow row;
    private PhotoFileReader reader;
    private PhotoFileReader mimic_reader = null;
    private PixelTransformer transformer = null;
    private PixelTransformationBundle adjustments = null;
    private string title = null;
    
    // The key to this implementation is that multiple instances of TransformablePhoto with the
    // same PhotoID cannot exist; it is up to the subclasses to ensure this.
    protected TransformablePhoto(PhotoRow row) {
        this.row = row;
        this.reader = row.file_format.create_reader(row.filepath);
        
        // get the title of the Photo without using a File object, skipping the separator itself
        char *basename = row.filepath.rchr(-1, Path.DIR_SEPARATOR);
        if (basename != null)
            title = (string) (basename + 1);
        
        if (title == null || title[0] == '\0')
            title = row.filepath;
    }
    
    // For the MimicManager
    public bool would_use_mimic() {
        bool result;
        lock (row) {
            PhotoFileFormatFlags flags = reader.get_file_format().get_properties().get_flags();
            result = (flags & PhotoFileFormatFlags.MIMIC_RECOMMENDED) != 0;
        }
        
        return result;
    }
    
    // For an MimicManager
    public void set_mimic(PhotoFileReader mimic_reader) {
        if (no_mimicked_images)
            return;
        
        lock (row) {
            this.mimic_reader = mimic_reader;
        }
    }
    
    // This method interrogates the specified file and returns a PhotoRow with all relevant
    // information about it.  It uses the PhotoFileInterrogator to do so.  The caller should create
    // a PhotoFileInterrogator with the proper options prior to calling.  prepare_for_import()
    // will determine what's been discovered and fill out in the PhotoRow or return the relevant
    // objects and information.  If Thumbnails is not null, thumbnails suitable for caching or
    // framing will be returned as well.  Note that this method will call interrogate() and
    // perform all error-handling; the caller simply needs to construct the object.
    //
    // This is the acid-test; if unable to generate a pixbuf or thumbnails, that indicates the 
    // photo itself is bogus and should be discarded.
    //
    // NOTE: This method is thread-safe.
    public static ImportResult prepare_for_import(File file, ImportID import_id,
        PhotoFileSniffer.Options options, out PhotoRow photo_row, Thumbnails? thumbnails) {
#if MEASURE_IMPORT
        Timer total_time = new Timer();
#endif
        FileInfo info = null;
        try {
            info = file.query_info("standard::*", FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
        } catch (Error err) {
            return ImportResult.FILE_ERROR;
        }
        
        if (info.get_file_type() != FileType.REGULAR)
            return ImportResult.NOT_A_FILE;
        
        if (!is_file_image(file)) {
            message("Not importing %s: Not an image file", file.get_path());
            
            return ImportResult.NOT_AN_IMAGE;
        }

        if (!is_file_supported(file)) {
            message("Not importing %s: Unsupported extension", file.get_path());
            
            return ImportResult.UNSUPPORTED_FORMAT;
        }
        
        TimeVal timestamp;
        info.get_modification_time(out timestamp);
        
        // interrogate file for photo information
        PhotoFileInterrogator interrogator = new PhotoFileInterrogator(file, options);
        try {
            interrogator.interrogate();
        } catch (Error err) {
            warning("Unable to interrogate photo file %s: %s", file.get_path(), err.message);
            
            return ImportResult.DECODE_ERROR;
        }
        
        // if not detected photo information, unsupported
        DetectedPhotoInformation? detected = interrogator.get_detected_photo_information();
        if (detected == null)
            return ImportResult.UNSUPPORTED_FORMAT;
        
        Orientation orientation = Orientation.TOP_LEFT;
        time_t exposure_time = 0;
        
        if (detected.exif != null) {
            if (!Exif.get_timestamp(detected.exif, out exposure_time))
                warning("Unable to read EXIF timestamp for %s", file.get_path());
            
            orientation = Exif.get_orientation(detected.exif);
        }
        
        // verify basic mechanics of photo: RGB 8-bit encoding
        if (detected.colorspace != Gdk.Colorspace.RGB 
            || detected.channels < 3 
            || detected.bits_per_channel != 8) {
            message("Not importing %s: Unsupported color format", file.get_path());
            
            return ImportResult.UNSUPPORTED_FORMAT;
        }
        
        // photo information is initially stored in database in raw, non-modified format ... this is
        // especially important dealing with dimensions and orientation ... Don't trust EXIF
        // dimensions, they can lie or not be present
        photo_row.photo_id = PhotoID();
        photo_row.filepath = file.get_path();
        photo_row.dim = detected.image_dim;
        photo_row.filesize = info.get_size();
        photo_row.timestamp = timestamp.tv_sec;
        photo_row.exposure_time = exposure_time;
        photo_row.orientation = orientation;
        photo_row.original_orientation = orientation;
        photo_row.import_id = import_id;
        photo_row.event_id = EventID();
        photo_row.transformations = null;
        photo_row.md5 = detected.md5;
        photo_row.thumbnail_md5 = detected.thumbnail_md5;
        photo_row.exif_md5 = detected.exif_md5;
        photo_row.time_created = 0;
        photo_row.flags = 0;
        photo_row.file_format = detected.file_format;
        
        if (thumbnails != null) {
            // can't use the pixbuf, if it was fetched, because it might not be (and most likely
            // isn't) full-sized, in which case, the thumbnails would be doubly scaled
            PhotoFileReader reader = photo_row.file_format.create_reader(photo_row.filepath);
            try {
                ThumbnailCache.generate(thumbnails, reader, photo_row.orientation, photo_row.dim);
            } catch (Error err) {
                return ImportResult.convert_error(err, ImportResult.FILE_ERROR);
            }
        }
        
#if MEASURE_IMPORT
        debug("IMPORT: total=%lf", total_time.elapsed());
#endif
        return ImportResult.SUCCESS;
    }
    
    public static bool is_file_supported(File file) {
        return is_basename_supported(file.get_basename());
    }
    
    public static bool is_basename_supported(string basename) {
        string name, ext;
        disassemble_filename(basename, out name, out ext);
        if (ext == null)
            return false;
        
        // treat extensions as case-insensitive
        ext = ext.down();
        
        // search support file formats
        foreach (PhotoFileFormat file_format in PhotoFileFormat.get_supported()) {
            if (file_format.get_properties().is_recognized_extension(ext))
                return true;
        }
        
        return false;
    }
    
    public static bool is_file_image(File file) {
        return is_extension_found(file.get_basename(), IMAGE_EXTENSIONS);
    }
    
    private static bool is_extension_found(string basename, string[] extensions) {
        string name, ext;
        disassemble_filename(basename, out name, out ext);
        if (ext == null)
            return false;
        
        // treat extensions as case-insensitive
        ext = ext.down();
        
        // search supported list
        foreach (string extension in extensions) {
            if (ext == extension)
                return true;
        }
        
        return false;
    }
    
    // This is not thread-safe.
    public static bool is_duplicate(File? file, string? exif_md5, string? thumbnail_md5,
        string? full_md5) {
#if !NO_DUPE_DETECTION
        return PhotoTable.get_instance().has_duplicate(file, exif_md5, thumbnail_md5, full_md5);
#else
        return false;
#endif
    }
    
    // Data element accessors ... by making these thread-safe, and by the remainder of this class
    // (and subclasses) accessing row *only* through these, helps ensure this object is suitable
    // for threads.  This implementation is specifically for PixbufCache to work properly.
    //
    // Much of the setter's thread-safety (especially in regard to writing to the database) is
    // that there is a single Photo object per row of the database.  The PhotoTable is accessed
    // elsewhere in the system (usually for aggregate and search functions).  Those would need to
    // be factored and locked in order to guarantee full thread safety.
    //
    // Note that return inside a lock block generates warnings and does not properly release the
    // mutex: https://bugzilla.gnome.org/show_bug.cgi?id=582553
    //
    // Also note there is a certain amount of paranoia here.  Many of PhotoRow's elements are
    // currently static, with no setters to change them.  However, since some of these may become
    // mutable in the future, the entire structure is locked.  If performance becomes an issue,
    // more fine-tuned locking may be implemented -- another reason to *only* use these getters
    // and setters inside this class.
    
    public File get_file() {
        File file;
        lock (row) {
            file = reader.get_file();
        }
        
        return file;
    }
    
    // Returns the file generating pixbufs, that is, the mimic if present, the backing
    // file if not.
    public File get_actual_file() {
        File file;
        lock (row) {
            PhotoFileReader actual = mimic_reader ?? reader;
            file = actual.get_file();
        }
        
        return file;
    }
    
    public bool is_mimicked() {
        bool result;
        lock (row) {
            result = mimic_reader != null;
        }
        
        return result;
    }
    
    public time_t get_timestamp() {
        time_t timestamp;
        lock (row) {
            timestamp = row.timestamp;
        }
        
        return timestamp;
    }

    public PhotoID get_photo_id() {
        PhotoID photo_id;
        lock (row) {
            photo_id = row.photo_id;
        }
        
        return photo_id;
    }
    
    public EventID get_event_id() {
        EventID event_id;
        lock (row) {
            event_id = row.event_id;
        }
        
        return event_id;
    }
    
    // Flags' meanings are determined by subclasses.  Top 16 flags (0xFFFF000000000000) reserved
    // for TransformablePhoto.
    public uint64 get_flags() {
        uint64 flags;
        lock (row) {
            flags = row.flags;
        }
        
        return flags;
    }
    
    public uint64 set_flags(uint64 flags) {
        bool committed;
        lock (row) {
            committed = PhotoTable.get_instance().set_flags(get_photo_id(), flags);
            if (committed)
                row.flags = flags;
        }
        
        if (committed)
            notify_metadata_altered();
        
        return flags;
    }
    
    public bool is_flag_set(uint64 mask) {
        bool is_set;
        lock (row) {
            is_set = (row.flags & mask) != 0;
        }
        
        return is_set;
    }
    
    public uint64 add_flags(uint64 mask) {
        uint64 flags = 0;
        
        bool committed = false;
        lock (row) {
            flags = row.flags | mask;
            if (row.flags != flags) {
                committed = PhotoTable.get_instance().set_flags(get_photo_id(), flags);
                if (committed)
                    row.flags = flags;
            }
        }
        
        if (committed)
            notify_metadata_altered();
        
        return flags;
    }
    
    public uint64 remove_flags(uint64 mask) {
        uint64 flags = 0;
        
        bool committed = false;
        lock (row) {
            flags = row.flags & ~mask;
            if (row.flags != flags) {
                committed = PhotoTable.get_instance().set_flags(get_photo_id(), flags);
                if (committed)
                    row.flags = flags;
            }
        }
        
        if (committed)
            notify_metadata_altered();
        
        return flags;
    }
    
    public uint64 add_remove_flags(uint64 add, uint64 remove) {
        uint64 flags = 0;
        
        bool committed = false;
        lock (row) {
            flags = (row.flags | add) & ~remove;
            if (row.flags != flags) {
                committed = PhotoTable.get_instance().set_flags(get_photo_id(), flags);
                if (committed)
                    row.flags = flags;
            }
        }
        
        if (committed)
            notify_metadata_altered();
        
        return flags;
    }
    
    public uint64 toggle_flags(uint64 mask) {
        uint64 flags = 0;
        
        bool committed = false;
        lock (row) {
            flags = row.flags ^ mask;
            if (row.flags != flags) {
                committed = PhotoTable.get_instance().set_flags(get_photo_id(), flags);
                if (committed)
                    row.flags = flags;
            }
        }
        
        if (committed)
            notify_metadata_altered();
        
        return flags;
    }
    
    public Event? get_event() {
        EventID event_id = get_event_id();
        
        return event_id.is_valid() ? Event.global.fetch(event_id) : null;
    }
    
    public bool set_event(Event? event) {
        bool committed = false;
        bool success = false;
        lock (row) {
            EventID event_id = (event != null) ? event.get_event_id() : EventID();
            if (row.event_id.id == event_id.id) {
                success = true;
            } else {
                committed = PhotoTable.get_instance().set_event(row.photo_id, event_id);
                if (committed) {
                    row.event_id = event_id;
                    success = true;
                }
            }
        }
        
        if (committed)
            notify_metadata_altered();
        
        return success;
    }
    
    public override string to_string() {
        return "[%lld] %s%s".printf(get_photo_id().id, get_actual_file().get_path(),
            is_mimicked() ? " (" + get_file().get_path() + ")" : "");
    }

    public override bool equals(DataSource? source) {
        // Primary key is where the rubber hits the road
        TransformablePhoto? photo = source as TransformablePhoto;
        if (photo != null) {
            PhotoID photo_id = get_photo_id();
            PhotoID other_photo_id = photo.get_photo_id();
            
            if (this != photo) {
                assert(photo_id.id != other_photo_id.id);
            }
        }
        
        return base.equals(source);
    }
    
    // TODO: This method is currently only called by DirectPhoto, and as such currently doesn't
    // take into account properly updating a LibraryPhoto.  More work needs to be done here.
    public void update() throws Error {
        File file = get_file();

        // TODO: Try to read JFIF metadata too
        FileInfo info = null;
        try {
            info = file.query_info("*", FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
        } catch (Error err) {
            error("Unable to read file information for %s: %s", file.get_path(), err.message);
        }
        
        TimeVal timestamp = TimeVal();
        info.get_modification_time(out timestamp);

        // interrogate file for photo information
        PhotoFileInterrogator interrogator = new PhotoFileInterrogator(file);
        interrogator.interrogate();
        DetectedPhotoInformation? detected = interrogator.get_detected_photo_information();
        if (detected == null) {
            critical("Photo update: %s no longer an image", to_string());
            
            return;
        }

        Orientation orientation = Orientation.TOP_LEFT;
        time_t exposure_time = 0;

        if (detected.exif != null) {
            orientation = Exif.get_orientation(detected.exif);
            Exif.get_timestamp(detected.exif, out exposure_time);
        }
        
        PhotoID photo_id = get_photo_id();
        if (PhotoTable.get_instance().update(photo_id, detected.image_dim, info.get_size(), timestamp.tv_sec, 
            exposure_time, orientation, detected.file_format, detected.md5, detected.exif_md5, 
            detected.thumbnail_md5)) {
            // cache coherency
            lock (row) {
                row.dim = detected.image_dim;
                row.filesize = info.get_size();
                row.timestamp = timestamp.tv_sec;
                row.exposure_time = exposure_time;
                row.orientation = orientation;
                row.original_orientation = orientation;
                row.md5 = detected.md5;
                row.exif_md5 = detected.exif_md5;
                row.thumbnail_md5 = detected.thumbnail_md5;
                row.file_format = detected.file_format;
                
                // build new reader and clear mimic
                reader = row.file_format.create_reader(row.filepath);
                mimic_reader = null;
                
                // because image has changed, all transformations are suspect
                remove_all_transformations();
            }
            
            // metadata currently only means Event
            notify_altered();
            notify_metadata_altered();
        }
    }
    
    // used to update the database after an internal metadata exif write
    private void file_exif_updated() {
        File file = get_file();
    
        FileInfo info = null;
        try {
            info = file.query_info("*", FileQueryInfoFlags.NOFOLLOW_SYMLINKS, null);
        } catch (Error err) {
            error("Unable to read file information for %s: %s", to_string(), err.message);
        }
        
        TimeVal timestamp = TimeVal();
        info.get_modification_time(out timestamp);
        
        // interrogate file for photo information
        PhotoFileInterrogator interrogator = new PhotoFileInterrogator(file);
        try {
            interrogator.interrogate();
        } catch (Error err) {
            warning("Unable to interrogate photo file %s: %s", file.get_path(), err.message);
        }
        
        DetectedPhotoInformation? detected = interrogator.get_detected_photo_information();
        if (detected == null) {
            critical("file_exif_updated: %s no longer an image", to_string());
            
            return;
        }
        
        if (PhotoTable.get_instance().file_exif_updated(get_photo_id(), info.get_size(),
            timestamp.tv_sec, detected.md5, detected.exif_md5, detected.thumbnail_md5)) {
            // cache coherency
            lock (row) {
                row.filesize = info.get_size();
                row.timestamp = timestamp.tv_sec;
                row.md5 = detected.md5;
                row.exif_md5 = detected.exif_md5;
                row.thumbnail_md5 = detected.thumbnail_md5;
            }
            
            // metadata currently only means Event
            notify_metadata_altered();
        }
    }

    // PhotoSource
    
    public override string get_name() {
        return title;
    }
    
    public override uint64 get_filesize() {
        uint64 filesize;
        lock (row) {
            filesize = row.filesize;
        }
        
        return filesize;
    }
    
    public override time_t get_exposure_time() {
        time_t exposure_time;
        lock (row) {
            exposure_time = row.exposure_time;
        }
        
        return exposure_time;
    }

    public void set_exposure_time(time_t time) {
        bool committed;
        lock (row) {
            committed = PhotoTable.get_instance().set_exposure_time(row.photo_id, time);
            if (committed)
                row.exposure_time = time;
        }
        
        if (committed)
            notify_metadata_altered();
    }

    public void set_exposure_time_persistent(time_t time) throws Error {
        // Try to write to backing file
        if (!reader.get_file_format().can_write()) {
            warning("No photo file writer available for %s", reader.get_filepath());
            
            set_exposure_time(time);
            
            return;
        }
        
        Exif.Data exif = reader.read_exif();
        Exif.set_timestamp(exif, time);
        
        PhotoFileWriter writer = reader.create_writer();
        writer.write_exif(exif);
        
        set_exposure_time(time);
        
        file_exif_updated();
    }
    
    // Returns cropped and rotated dimensions
    public override Dimensions get_dimensions() {
        Box crop;
        if (get_crop(out crop))
            return crop.get_dimensions();
        
        return get_original_dimensions();
    }
    
    // This method *must* be called with row locked.
    private void locked_create_adjustments_from_data() {
        adjustments = new PixelTransformationBundle();
        
        KeyValueMap map = get_transformation("adjustments");
        if (map == null)
            adjustments.set_to_identity();
        else
            adjustments.load(map);
        
        transformer = adjustments.generate_transformer();
    }
    
    // Returns a copy of the color adjustments array.  Use set_color_adjustments to persist.
    public PixelTransformationBundle get_color_adjustments() {
        PixelTransformationBundle result = new PixelTransformationBundle();
        lock (row) {
            if (adjustments == null)
                locked_create_adjustments_from_data();
            
            result = adjustments.copy();
        }
        
        return result;
    }
    
    private PixelTransformer get_pixel_transformer() {
        PixelTransformer result;
        lock (row) {
            if (transformer == null)
                locked_create_adjustments_from_data();
            
            result = transformer.copy();
        }
        
        return result;
    }

    public bool has_color_adjustments() {
        return has_transformation("adjustments");
    }
    
    public PixelTransformation? get_color_adjustment(PixelTransformationType type) {
        return get_color_adjustments().get_transformation(type);
    }

    public void set_color_adjustments(PixelTransformationBundle new_adjustments) {
        /* if every transformation in 'new_adjustments' is the identity, then just remove all
           adjustments from the database */
        if (new_adjustments.is_identity()) {
            bool result;
            lock (row) {
                result = remove_transformation("adjustments");
                adjustments = null;
                transformer = null;
            }
            
            if (result)
                notify_altered();

            return;
        }
        
        // convert bundle to KeyValueMap, which can be saved in the database
        KeyValueMap map = new_adjustments.save("adjustments");
        
        bool committed;
        lock (row) {
            if (transformer == null || adjustments == null) {
                // create new 
                adjustments = new_adjustments.copy();
                transformer = new_adjustments.generate_transformer();
            } else {
                // replace existing
                foreach (PixelTransformation transformation in new_adjustments.get_transformations()) {
                    transformer.replace_transformation(
                        adjustments.get_transformation(transformation.get_transformation_type()),
                        transformation);
                }
                
                adjustments = new_adjustments.copy();
            }

            committed = set_transformation(map);
        }
        
        if (committed)
            notify_altered();
    }
    
    public override Exif.Data? get_exif() {
        Exif.Data? exif = null;
        try {
            exif = reader.read_exif();
        } catch (Error err) {
            // return null
            warning("Unable to load EXIF from %s: %s", reader.get_filepath(), err.message);
        }
        
        return exif;
    }
    
    // Transformation storage and exporting

    public Dimensions get_raw_dimensions() {
        Dimensions dim;
        lock (row) {
            dim = row.dim;
        }
        
        return dim;
    }

    public bool has_transformations() {
        bool transformed;
        lock (row) {
            if (row.orientation != row.original_orientation)
                transformed = true;
            else
                transformed = row.transformations != null;
        }
        
        return transformed;
    }
    
    public bool only_exif_changed() {
        bool exif_changed;
        
        time_t exposure_time = 0;
        bool compare_time = false;
        
        Exif.Data? exif = get_exif();
        if (exif != null)
            compare_time = Exif.get_timestamp(exif, out exposure_time);
        
        lock (row) {
            exif_changed = row.transformations == null && 
                          (row.orientation != row.original_orientation ||
                           (compare_time && row.exposure_time != exposure_time));
        }
        
        return exif_changed;
    }
    
    public bool has_alterations() {
        bool altered;
        
        time_t exposure_time = 0;
        bool compare_time = false;
        
        Exif.Data? exif = get_exif();
        if (exif != null)
            compare_time = Exif.get_timestamp(exif, out exposure_time);
        
        lock (row) {
            altered = row.transformations != null || row.orientation != row.original_orientation ||
                (compare_time && row.exposure_time != exposure_time);
        }
        
        return altered;
    }
    
    public PhotoTransformationState save_transformation_state() {
        PhotoTransformationState state = null;
        lock (row) {
            state = new PhotoTransformationStateImpl(this);
        }
        
        return state;
    }
    
    public bool load_transformation_state(PhotoTransformationState state) {
        PhotoTransformationStateImpl state_impl = state as PhotoTransformationStateImpl;
        if (state_impl == null)
            return false;
        
        Orientation saved_orientation = state_impl.get_orientation();
        Gee.HashMap<string, KeyValueMap>? saved_transformations = state_impl.get_transformations();
        PixelTransformer? saved_transformer = state_impl.get_transformer();
        PixelTransformationBundle saved_adjustments = state_impl.get_color_adjustments();
        
        bool committed;
        lock (row) {
            committed = PhotoTable.get_instance().set_transformation_state(row.photo_id,
                saved_orientation, saved_transformations);
            if (committed) {
                row.orientation = saved_orientation;
                row.transformations = saved_transformations;
                transformer = saved_transformer;
                adjustments = saved_adjustments;
            }
        }
        
        if (committed)
            notify_altered();
        
        return committed;
    }
    
    public void remove_all_transformations() {
        bool is_altered = false;
        lock (row) {
            is_altered = PhotoTable.get_instance().remove_all_transformations(row.photo_id);
            row.transformations = null;
            
            transformer = null;
            adjustments = null;
            
            if (row.orientation != row.original_orientation) {
                PhotoTable.get_instance().set_orientation(row.photo_id, row.original_orientation);
                row.orientation = row.original_orientation;
                is_altered = true;
            }
        }

        if (is_altered)
            notify_altered();
    }
    
    public Orientation get_original_orientation() {
        Orientation original_orientation;
        lock (row) {
            original_orientation = row.original_orientation;
        }
        
        return original_orientation;
    }
    
    public Orientation get_orientation() {
        Orientation orientation;
        lock (row) {
            orientation = row.orientation;
        }
        
        return orientation;
    }
    
    public bool set_orientation(Orientation orientation) {
        bool committed;
        lock (row) {
            committed = PhotoTable.get_instance().set_orientation(row.photo_id, orientation);
            if (committed)
                row.orientation = orientation;
        }
        
        if (committed)
            notify_altered();
        
        return committed;
    }

    public virtual void rotate(Rotation rotation) {
        lock (row) {
            Orientation orientation = get_orientation();
            
            orientation = orientation.perform(rotation);
            
            set_orientation(orientation);
        }
    }

    private bool has_transformation(string name) {
        bool present;
        lock (row) {
            present = (row.transformations != null) ? row.transformations.has_key(name) : false;
        }
        
        return present;
    }
    
    // Note that obtaining the proper map is thread-safe here.  The returned map is a copy of
    // the original, so it is thread-safe as well.  However: modifying the returned map
    // does not modify the original; set_transformation() must be used.
    private KeyValueMap? get_transformation(string name) {
        KeyValueMap map = null;
        lock (row) {
            if (row.transformations != null) {
                map = row.transformations.get(name);
                if (map != null)
                    map = map.copy();
            }
        }
        
        return map;
    }
    
    private bool set_transformation(KeyValueMap trans) {
        bool committed;
        lock (row) {
            if (row.transformations == null)
                row.transformations = new Gee.HashMap<string, KeyValueMap>(str_hash, str_equal, direct_equal);
            
            row.transformations.set(trans.get_group(), trans);
            
            committed = PhotoTable.get_instance().set_transformation(row.photo_id, trans);
        }
        
        return committed;
    }

    private bool remove_transformation(string name) {
        bool altered_cache, altered_persistent;
        lock (row) {
            if (row.transformations != null) {
                altered_cache = row.transformations.unset(name);
                if (row.transformations.size == 0)
                    row.transformations = null;
            } else {
                altered_cache = false;
            }
            
            altered_persistent = PhotoTable.get_instance().remove_transformation(row.photo_id, 
                name);
        }

        return (altered_cache || altered_persistent);
    }

    public bool has_crop() {
        return has_transformation("crop");
    }

    // Returns the crop in the raw photo's coordinate system
    private bool get_raw_crop(out Box crop) {
        KeyValueMap map = get_transformation("crop");
        if (map == null)
            return false;
        
        int left = map.get_int("left", -1);
        int top = map.get_int("top", -1);
        int right = map.get_int("right", -1);
        int bottom = map.get_int("bottom", -1);
        
        if (left == -1 || top == -1 || right == -1 || bottom == -1)
            return false;
        
        crop = Box(left, top, right, bottom);
        
        return true;
    }
    
    // Sets the crop using the raw photo's unrotated coordinate system
    private void set_raw_crop(Box crop) {
        KeyValueMap map = new KeyValueMap("crop");
        map.set_int("left", crop.left);
        map.set_int("top", crop.top);
        map.set_int("right", crop.right);
        map.set_int("bottom", crop.bottom);
        
        if (set_transformation(map))
            notify_altered();
    }
    
    // All instances are against the coordinate system of the unscaled, unrotated photo.
    private RedeyeInstance[] get_raw_redeye_instances() {
        KeyValueMap map = get_transformation("redeye");
        if (map == null)
            return new RedeyeInstance[0];
        
        int num_points = map.get_int("num_points", -1);
        assert(num_points > 0);

        RedeyeInstance[] res = new RedeyeInstance[num_points];

        Gdk.Point default_point = {0};
        default_point.x = -1;
        default_point.y = -1;

        for (int i = 0; i < num_points; i++) {
            string center_key = "center%d".printf(i);
            string radius_key = "radius%d".printf(i);

            res[i].center = map.get_point(center_key, default_point);
            assert(res[i].center.x != default_point.x);
            assert(res[i].center.y != default_point.y);

            res[i].radius = map.get_int(radius_key, -1);
            assert(res[i].radius != -1);
        }

        return res;
    }
    
    public bool has_redeye_transformations() {
        return has_transformation("redeye");
    }

    // All instances are against the coordinate system of the unrotated photo.
    private void add_raw_redeye_instance(RedeyeInstance redeye) {
        KeyValueMap map = get_transformation("redeye");
        if (map == null) {
            map = new KeyValueMap("redeye");
            map.set_int("num_points", 0);
        }
        
        int num_points = map.get_int("num_points", -1);
        assert(num_points >= 0);
        
        num_points++;
        
        string radius_key = "radius%d".printf(num_points - 1);
        string center_key = "center%d".printf(num_points - 1);
        
        map.set_int(radius_key, redeye.radius);
        map.set_point(center_key, redeye.center);
        
        map.set_int("num_points", num_points);

        if (set_transformation(map))
            notify_altered();
    }

    // Pixbuf generation
    
    // Returns dimensions for the pixbuf at various stages of the pipeline.
    //
    // scaled_image is the dimensions of the image after a scaled load-and-decode.
    // scaled_to_viewport is the dimensions of the image sized according to the scaling parameter.
    // scaled_image and scaled_to_viewport may be different if the photo is cropped.
    //
    // Returns true if scaling is to occur, false otherwise.  If false, scaled_image will be set to
    // the raw image dimensions and scaled_to_viewport will be the dimensions of the image scaled
    // to the Scaling viewport.
    private bool calculate_pixbuf_dimensions(Scaling scaling, Exception exceptions, 
        out Dimensions scaled_image, out Dimensions scaled_to_viewport) {
        bool scaling_required;
        lock (row) {
            // this function needs to access various elements of the Photo atomically
            scaling_required = locked_calculate_pixbuf_dimensions(scaling, exceptions,
                out scaled_image, out scaled_to_viewport);
        }
        
        return scaling_required;
    }
    
    // Must be called with row locked.
    private bool locked_calculate_pixbuf_dimensions(Scaling scaling, Exception exceptions,
        out Dimensions scaled_image, out Dimensions scaled_to_viewport) {
        Dimensions raw = get_raw_dimensions();
        
        if (scaling.is_unscaled()) {
            scaled_image = raw;
            scaled_to_viewport = raw;
            
            return false;
        }
        
        Orientation orientation = get_orientation();
        
        // If no crop, the scaled_image is simply raw scaled to fit into the viewport.  Otherwise,
        // the image is scaled enough so the cropped region fits the viewport.

        scaled_image = Dimensions();
        scaled_to_viewport = Dimensions();
        
        if (exceptions.allows(Exception.CROP)) {
            Box crop;
            if (get_raw_crop(out crop)) {
                // rotate the crop and raw space accordingly ... order is important here, rotate_box
                // works with the unrotated dimensions in space
                Dimensions rotated_raw = raw;
                if (exceptions.allows(Exception.ORIENTATION)) {
                    crop = orientation.rotate_box(raw, crop);
                    rotated_raw = orientation.rotate_dimensions(raw);
                }
                
                // scale the rotated crop to fit in the viewport
                Box scaled_crop = crop.get_scaled(scaling.get_scaled_dimensions(crop.get_dimensions()));
                
                // the viewport size is the size of the scaled crop
                scaled_to_viewport = scaled_crop.get_dimensions();
                    
                // only scale the image if the crop is larger than the viewport
                if (crop.get_width() <= scaled_crop.get_width() 
                    && crop.get_height() <= scaled_crop.get_height()) {
                    scaled_image = raw;
                    scaled_to_viewport = crop.get_dimensions();
                    
                    return false;
                }
                // resize the total pixbuf so the crop slices directly from the scaled pixbuf, 
                // with no need for resizing thereafter.  The decoded size is determined by the 
                // proportion of the actual size to the crop size
                scaled_image = rotated_raw.get_scaled_similar(crop.get_dimensions(), 
                    scaled_crop.get_dimensions());
                
                // derotate, as the loader knows nothing about orientation
                if (exceptions.allows(Exception.ORIENTATION))
                    scaled_image = orientation.derotate_dimensions(scaled_image);
            }
        }
        
        // if scaled_image not set, merely scale the raw pixbuf
        if (!scaled_image.has_area()) {
            // rotate for the scaler
            Dimensions rotated_raw = raw;
            if (exceptions.allows(Exception.ORIENTATION))
                rotated_raw = orientation.rotate_dimensions(raw);

            scaled_image = scaling.get_scaled_dimensions(rotated_raw);
            scaled_to_viewport = scaled_image;
        
            // derotate the scaled dimensions, as the loader knows nothing about orientation
            if (exceptions.allows(Exception.ORIENTATION))
                scaled_image = orientation.derotate_dimensions(scaled_image);
        }

        // do not scale up
        if (scaled_image.width >= raw.width && scaled_image.height >= raw.height) {
            scaled_image = raw;
            
            return false;
        }
        
        assert(scaled_image.has_area());
        assert(scaled_to_viewport.has_area());
        
        return true;
    }

    // Returns a raw, untransformed, unrotated pixbuf directly from the source.  Scaling provides
    // asked for a scaled-down image, which has certain performance benefits if the resized
    // JPEG is scaled down by a factor of a power of two (one-half, one-fourth, etc.).
    private Gdk.Pixbuf load_raw_pixbuf(Scaling scaling, Exception exceptions) throws Error {
        PhotoFileReader loader;
        lock (row) {
            loader = mimic_reader ?? reader;
        }
        
        // no scaling, load and get out
        if (scaling.is_unscaled()) {
#if MEASURE_PIPELINE
            debug("LOAD_RAW_PIXBUF UNSCALED %s: requested", path);
#endif
            
            return loader.unscaled_read();
        }
        
        // Need the dimensions of the image to load
        Dimensions scaled_image, scaled_to_viewport;
        bool is_scaled = calculate_pixbuf_dimensions(scaling, exceptions, out scaled_image, 
            out scaled_to_viewport);
        if (!is_scaled) {
#if MEASURE_PIPELINE
            debug("LOAD_RAW_PIXBUF UNSCALED %s: scaling unavailable", path);
#endif
            
            return loader.unscaled_read();
        }
        
        Gdk.Pixbuf pixbuf = loader.scaled_read(get_raw_dimensions(), scaled_image);
        
#if MEASURE_PIPELINE
        debug("LOAD_RAW_PIXBUF %s %s: %s -> %s (actual: %s)", scaling.to_string(), path,
            get_raw_dimensions().to_string(), scaled_image.to_string(), 
            Dimensions.for_pixbuf(pixbuf).to_string());
#endif
        
        assert(scaled_image.approx_equals(Dimensions.for_pixbuf(pixbuf), SCALING_FUDGE));
        
        return pixbuf;
    }

    // Returns a raw, untransformed, scaled pixbuf from the source that has been rotated
    // according to its original EXIF settings
    public Gdk.Pixbuf get_original_pixbuf(Scaling scaling) throws Error {
#if MEASURE_PIPELINE
        Timer timer = new Timer();
        Timer total_timer = new Timer();
        double orientation_time = 0.0;
        
        total_timer.start();
#endif
        // get required fields all at once, to avoid holding the row lock
        Dimensions scaled_image, scaled_to_viewport;
        Orientation original_orientation;
        
        lock (row) {
            calculate_pixbuf_dimensions(scaling, Exception.NONE, out scaled_image, 
                out scaled_to_viewport);
            original_orientation = get_original_orientation();
        }
        
        // load-and-decode and scale
        Gdk.Pixbuf pixbuf = load_raw_pixbuf(scaling, Exception.NONE);
            
        // orientation
#if MEASURE_PIPELINE
        timer.start();
#endif
        pixbuf = original_orientation.rotate_pixbuf(pixbuf);
#if MEASURE_PIPELINE
        orientation_time = timer.elapsed();
        
        debug("ORIGINAL PIPELINE %s (%s): orientation=%lf total=%lf", to_string(), scaling.to_string(),
            orientation_time, total_timer.elapsed());
#endif
        
        return pixbuf;
    }

    // A preview pixbuf is one that can be quickly generated and scaled as a preview.  It is fully 
    // transformed.
    //
    // Note that an unscaled scaling is not considered a performance-killer for this method, 
    // although the quality of the pixbuf may be quite poor compared to the actual unscaled 
    // transformed pixbuf.
    public abstract Gdk.Pixbuf get_preview_pixbuf(Scaling scaling) throws Error;
    
    public override Gdk.Pixbuf get_pixbuf(Scaling scaling) throws Error {
        return get_pixbuf_with_exceptions(scaling, Exception.NONE);
    }
    
    // Returns a fully transformed and scaled pixbuf.  Transformations may be excluded via the mask.
    // If the image is smaller than the scaling, it will be returned in its actual size.  The
    // caller is responsible for scaling thereafter.
    //
    // Note that an unscaled fetch can be extremely expensive, and it's far better to specify an 
    // appropriate scale.
    public Gdk.Pixbuf get_pixbuf_with_exceptions(Scaling scaling, Exception exceptions) throws Error {
#if MEASURE_PIPELINE
        Timer timer = new Timer();
        Timer total_timer = new Timer();
        double redeye_time = 0.0, crop_time = 0.0, adjustment_time = 0.0, orientation_time = 0.0;

        total_timer.start();
#endif
        // to minimize holding the row lock, fetch everything needed for the pipeline up-front
        bool is_scaled, is_cropped;
        Dimensions scaled_image, scaled_to_viewport;
        Dimensions original = Dimensions();
        Dimensions scaled = Dimensions();
        RedeyeInstance[] redeye_instances = null;
        Box crop;
        PixelTransformer transformer = null;
        Orientation orientation;
        
        lock (row) {
            // it's possible for get_raw_pixbuf to not return an image scaled to the spec'd scaling,
            // particularly when the raw crop is smaller than the viewport
            is_scaled = calculate_pixbuf_dimensions(scaling, exceptions, out scaled_image,
                out scaled_to_viewport);
            
            if (is_scaled)
                original = get_raw_dimensions();
            
            redeye_instances = get_raw_redeye_instances();
            
            is_cropped = get_raw_crop(out crop);
            
            if (has_color_adjustments())
                transformer = get_pixel_transformer();
            
            orientation = get_orientation();
        }
        
        //
        // Image load-and-decode
        //
        
        Gdk.Pixbuf pixbuf = load_raw_pixbuf(scaling, exceptions);
        
        if (is_scaled)
            scaled = Dimensions.for_pixbuf(pixbuf);
        
        //
        // Image transformation pipeline
        //
        
        // redeye reduction
        if (exceptions.allows(Exception.REDEYE)) {
#if MEASURE_PIPELINE
            timer.start();
#endif
            foreach (RedeyeInstance instance in redeye_instances) {
                // redeye is stored in raw coordinates; need to scale to scaled image coordinates
                if (is_scaled) {
                    instance.center = coord_scaled_in_space(instance.center.x, instance.center.y, 
                        original, scaled);
                    instance.radius = radius_scaled_in_space(instance.radius, original, scaled);
                    assert(instance.radius != -1);
                }
                
                pixbuf = do_redeye(pixbuf, instance);
            }
#if MEASURE_PIPELINE
            redeye_time = timer.elapsed();
#endif
        }

        // crop
        if (exceptions.allows(Exception.CROP)) {
#if MEASURE_PIPELINE
            timer.start();
#endif
            if (is_cropped) {
                // crop is stored in raw coordinates; need to scale to scaled image coordinates;
                // also, no need to do this if the image itself was unscaled (which can happen
                // if the crop is smaller than the viewport)
                if (is_scaled)
                    crop = crop.get_scaled_similar(original, scaled);
                
                pixbuf = new Gdk.Pixbuf.subpixbuf(pixbuf, crop.left, crop.top, crop.get_width(),
                    crop.get_height());
            }

#if MEASURE_PIPELINE
            crop_time = timer.elapsed();
#endif
        }
        
        // color adjustment
        if (exceptions.allows(Exception.ADJUST)) {
#if MEASURE_PIPELINE
            timer.start();
#endif
            if (transformer != null)
                transformer.transform_pixbuf(pixbuf);
#if MEASURE_PIPELINE
            adjustment_time = timer.elapsed();
#endif
        }

        // orientation (all modifications are stored in unrotated coordinate system)
        if (exceptions.allows(Exception.ORIENTATION)) {
#if MEASURE_PIPELINE
            timer.start();
#endif
            pixbuf = orientation.rotate_pixbuf(pixbuf);
#if MEASURE_PIPELINE
            orientation_time = timer.elapsed();
#endif
        }
        
        // this is to verify the generated pixbuf matches the scale requirements; crop and 
        // orientation are the only transformations that change the dimensions of the pixbuf, and
        // must be accounted for the test to be valid
        if (is_scaled)
            assert(scaled_to_viewport.approx_equals(Dimensions.for_pixbuf(pixbuf), SCALING_FUDGE));
        
#if MEASURE_PIPELINE
        debug("PIPELINE %s (%s): redeye=%lf crop=%lf adjustment=%lf orientation=%lf total=%lf",
            to_string(), scaling.to_string(), redeye_time, crop_time, adjustment_time, 
            orientation_time, total_timer.elapsed());
#endif
        
        return pixbuf;
    }
    
    //
    // File export
    //
    
    // Returns the basename of the file if it was exported in the supplied writeable file format.
    public string get_export_basename(PhotoFileFormat file_format) {
        return file_format.get_properties().convert_file_extension(get_file()).get_basename();
    }
    
    private bool export_fullsized_backing(File file) throws Error {
        // See if the native reader or the mimic supports writing ... if no matches, need to fall back
        // on a "regular" export, which requires decoding then encoding
        PhotoFileReader export_reader = null;
        lock (row) {
            if (reader.get_file_format().can_write())
                export_reader = reader;
            else if (mimic_reader != null && mimic_reader.get_file_format().can_write())
                export_reader = mimic_reader;
        }
        
        if (export_reader == null)
            return false;
        
        PhotoFileFormatProperties format_properties = export_reader.get_file_format().get_properties();
        
        // Build a destination file with the caller's name but the appropriate extension
        File dest_file = format_properties.convert_file_extension(file);
        
        // Create a PhotoFileWriter that matches the PhotoFileReader's file format
        PhotoFileWriter writer = export_reader.create_writer();
        
        debug("Exporting full-sized copy of %s to %s", to_string(), writer.get_filepath());
        
        export_reader.get_file().copy(dest_file, 
            FileCopyFlags.OVERWRITE | FileCopyFlags.TARGET_DEFAULT_PERMS, null, null);
        
        // If asking for an full-sized file and there are no alterations (transformations or
        // EXIF) *and* this is a copy of the original backing, then done
        if (!has_alterations() && export_reader == reader)
            return true;
        
        // copy over relevant EXIF
        Exif.Data? exif = export_reader.read_exif();
        if (exif == null) {
            // No EXIF, if copying from original backing, done, otherwise, keep going
            if (reader == export_reader)
                return true;
            
            exif = writer.new_exif();
        }
        
        debug("Updating EXIF of %s", writer.get_filepath());
        
        if (get_exposure_time() != 0)
            Exif.set_timestamp(exif, get_exposure_time());
        else
            Exif.remove_timestamp(exif);
        
        Exif.set_orientation(exif, get_orientation());
        
        if (get_orientation() != get_original_orientation())
            Exif.remove_thumbnail(exif);
        
        writer.write_exif(exif);
        
        return true;
    }
    
    // TODO: Lossless transformations, especially for mere rotations of JFIF files.
    public void export(File dest_file, Scaling scaling, Jpeg.Quality quality) throws Error {
        // Attempt to avoid decode/encoding cycle when exporting original-sized photos, as that
        // degrades image quality.  If alterations exist, but only EXIF has changed, then can copy
        // original file and update relevant EXIF.
        if (scaling.is_unscaled() && (!has_alterations() || only_exif_changed())) {
            if (export_fullsized_backing(dest_file))
                return;
        }
        
        // For now, only JPEG export is supported
        PhotoFileWriter writer = new JfifWriter(dest_file.get_path());
        
        debug("Saving transformed version of %s to %s", to_string(), writer.get_filepath());
        
        Gdk.Pixbuf pixbuf = get_pixbuf(scaling);
        Dimensions dim = Dimensions.for_pixbuf(pixbuf);
        
        writer.write(pixbuf, quality);
        
        debug("Setting EXIF for %s", writer.get_filepath());
        
        // copy over existing EXIF from source if available
        Exif.Data exif = get_exif();
        if (exif == null)
            return;
        
        Exif.set_dimensions(exif, dim);
        Exif.set_orientation(exif, Orientation.TOP_LEFT);
        if (get_exposure_time() != 0)
            Exif.set_timestamp(exif, get_exposure_time());
        else
            Exif.remove_timestamp(exif);
        Exif.remove_all_tags(exif, Exif.Tag.RELATED_IMAGE_WIDTH);
        Exif.remove_all_tags(exif, Exif.Tag.RELATED_IMAGE_LENGTH);
        Exif.remove_thumbnail(exif);
        
        writer.write_exif(exif);
    }
    
    //
    // Aggregate/helper/translation functions
    //
    
    // Returns uncropped (but rotated) dimensions
    public Dimensions get_original_dimensions() {
        Dimensions dim = get_raw_dimensions();
        Orientation orientation = get_orientation();
        
        return orientation.rotate_dimensions(dim);
    }
    
    // Returns the crop against the coordinate system of the rotated photo
    public bool get_crop(out Box crop) {
        Box raw;
        if (!get_raw_crop(out raw))
            return false;
        
        Dimensions dim = get_raw_dimensions();
        Orientation orientation = get_orientation();
        
        crop = orientation.rotate_box(dim, raw);
        
        return true;
    }
    
    // Sets the crop against the coordinate system of the rotated photo
    public void set_crop(Box crop) {
        Dimensions dim = get_raw_dimensions();
        Orientation orientation = get_orientation();

        Box derotated = orientation.derotate_box(dim, crop);
        
        assert(derotated.get_width() <= dim.width);
        assert(derotated.get_height() <= dim.height);
        
        set_raw_crop(derotated);
    }
    
    public void add_redeye_instance(RedeyeInstance inst_unscaled) {
        Gdk.Rectangle bounds_rect_unscaled = RedeyeInstance.to_bounds_rect(inst_unscaled);
        Gdk.Rectangle bounds_rect_raw = unscaled_to_raw_rect(bounds_rect_unscaled);
        RedeyeInstance inst = RedeyeInstance.from_bounds_rect(bounds_rect_raw);
        
        add_raw_redeye_instance(inst);
    }

    private Gdk.Pixbuf do_redeye(owned Gdk.Pixbuf pixbuf, owned RedeyeInstance inst) {
        /* we remove redeye within a circular region called the "effect
           extent." the effect extent is inscribed within its "bounding
           rectangle." */

        /* for each scanline in the top half-circle of the effect extent,
           compute the number of pixels by which the effect extent is inset
           from the edges of its bounding rectangle. note that we only have
           to do this for the first quadrant because the second quadrant's
           insets can be derived by symmetry */
        double r = (double) inst.radius;
        int[] x_insets_first_quadrant = new int[inst.radius + 1];
        
        int i = 0;
        for (double y = r; y >= 0.0; y -= 1.0) {
            double theta = Math.asin(y / r);
            int x = (int)((r * Math.cos(theta)) + 0.5);
            x_insets_first_quadrant[i] = inst.radius - x;
            
            i++;
        }

        int x_bounds_min = inst.center.x - inst.radius;
        int x_bounds_max = inst.center.x + inst.radius;
        int ymin = inst.center.y - inst.radius;
        ymin = (ymin < 0) ? 0 : ymin;
        int ymax = inst.center.y;
        ymax = (ymax > (pixbuf.height - 1)) ? (pixbuf.height - 1) : ymax;

        /* iterate over all the pixels in the top half-circle of the effect
           extent from top to bottom */
        int inset_index = 0;
        for (int y_it = ymin; y_it <= ymax; y_it++) {
            int xmin = x_bounds_min + x_insets_first_quadrant[inset_index];
            xmin = (xmin < 0) ? 0 : xmin;
            int xmax = x_bounds_max - x_insets_first_quadrant[inset_index];
            xmax = (xmax > (pixbuf.width - 1)) ? (pixbuf.width - 1) : xmax;

            for (int x_it = xmin; x_it <= xmax; x_it++) {
                red_reduce_pixel(pixbuf, x_it, y_it);
            }
            inset_index++;
        }

        /* iterate over all the pixels in the top half-circle of the effect
           extent from top to bottom */
        ymin = inst.center.y;
        ymax = inst.center.y + inst.radius;
        inset_index = x_insets_first_quadrant.length - 1;
        for (int y_it = ymin; y_it <= ymax; y_it++) {  
            int xmin = x_bounds_min + x_insets_first_quadrant[inset_index];
            xmin = (xmin < 0) ? 0 : xmin;
            int xmax = x_bounds_max - x_insets_first_quadrant[inset_index];
            xmax = (xmax > (pixbuf.width - 1)) ? (pixbuf.width - 1) : xmax;

            for (int x_it = xmin; x_it <= xmax; x_it++) {
                red_reduce_pixel(pixbuf, x_it, y_it);
            }
            inset_index--;
        }
        
        return pixbuf;
    }

    private Gdk.Pixbuf red_reduce_pixel(owned Gdk.Pixbuf pixbuf, int x, int y) {
        int px_start_byte_offset = (y * pixbuf.get_rowstride()) +
            (x * pixbuf.get_n_channels());
        
        unowned uchar[] pixel_data = pixbuf.get_pixels();
        
        /* The pupil of the human eye has no pigment, so we expect all
           color channels to be of about equal intensity. This means that at
           any point within the effects region, the value of the red channel
           should be about the same as the values of the green and blue
           channels. So set the value of the red channel to be the mean of the
           values of the red and blue channels. This preserves achromatic
           intensity across all channels while eliminating any extraneous flare
           affecting the red channel only (i.e. the red-eye effect). */
        uchar g = pixel_data[px_start_byte_offset + 1];
        uchar b = pixel_data[px_start_byte_offset + 2];
        
        uchar r = (g + b) / 2;
        
        pixel_data[px_start_byte_offset] = r;
        
        return pixbuf;
    }

    public Gdk.Point unscaled_to_raw_point(Gdk.Point unscaled_point) {
        Orientation unscaled_orientation = get_orientation();
    
        Dimensions unscaled_dims =
            unscaled_orientation.rotate_dimensions(get_dimensions());

        int unscaled_x_offset_raw = 0;
        int unscaled_y_offset_raw = 0;

        Box crop_box;
        if (get_raw_crop(out crop_box)) {
            unscaled_x_offset_raw = crop_box.left;
            unscaled_y_offset_raw = crop_box.top;
        }
        
        Gdk.Point derotated_point =
            unscaled_orientation.derotate_point(unscaled_dims,
            unscaled_point);

        derotated_point.x += unscaled_x_offset_raw;
        derotated_point.y += unscaled_y_offset_raw;

        return derotated_point;
    }
    
    public Gdk.Rectangle unscaled_to_raw_rect(Gdk.Rectangle unscaled_rect) {
        Gdk.Point upper_left = {0};
        Gdk.Point lower_right = {0};
        upper_left.x = unscaled_rect.x;
        upper_left.y = unscaled_rect.y;
        lower_right.x = upper_left.x + unscaled_rect.width;
        lower_right.y = upper_left.y + unscaled_rect.height;
        
        upper_left = unscaled_to_raw_point(upper_left);
        lower_right = unscaled_to_raw_point(lower_right);
        
        if (upper_left.x > lower_right.x) {
            int temp = upper_left.x;
            upper_left.x = lower_right.x;
            lower_right.x = temp;
        }
        if (upper_left.y > lower_right.y) {
            int temp = upper_left.y;
            upper_left.y = lower_right.y;
            lower_right.y = temp;
        }
        
        Gdk.Rectangle raw_rect = {0};
        raw_rect.x = upper_left.x;
        raw_rect.y = upper_left.y;
        raw_rect.width = lower_right.x - upper_left.x;
        raw_rect.height = lower_right.y - upper_left.y;
        
        return raw_rect;
    }

    public PixelTransformationBundle? get_enhance_transformations() {
        Gdk.Pixbuf pixbuf = null;

#if MEASURE_ENHANCE
        Timer fetch_timer = new Timer();
#endif

        try {
            pixbuf = get_pixbuf_with_exceptions(Scaling.for_best_fit(360, false), 
                TransformablePhoto.Exception.ALL);

#if MEASURE_ENHANCE
            fetch_timer.stop();
#endif
        } catch (Error e) {
            warning("Photo: get_enhance_transformations: couldn't obtain pixbuf to build " + 
                "transform histogram");
            return null;
        }

#if MEASURE_ENHANCE
        Timer analyze_timer = new Timer();
#endif

        PixelTransformationBundle transformations = AutoEnhance.create_auto_enhance_adjustments(pixbuf);

#if MEASURE_ENHANCE
        analyze_timer.stop();
        debug("Auto-Enhance fetch time: %f sec; analyze time: %f sec", fetch_timer.elapsed(),
            analyze_timer.elapsed());
#endif

        return transformations;
    }

    public bool enhance() {
        PixelTransformationBundle transformations = get_enhance_transformations();

        if (transformations == null)
            return false;

#if MEASURE_ENHANCE
        Timer apply_timer = new Timer();
#endif
        lock (row) {
            set_color_adjustments(transformations);
        }
        
#if MEASURE_ENHANCE
        apply_timer.stop();
        debug("Auto-Enhance apply time: %f sec", apply_timer.elapsed());
#endif
        return true;
    }
}

//
// Photo
//

public abstract class Photo : TransformablePhoto {
    public Photo(PhotoRow row) {
        base (row);
    }
}

public class LibraryPhotoSourceCollection : DatabaseSourceCollection {
    public LibraryPhotoSourceCollection() {
        base("LibraryPhotoSourceCollection", get_photo_key);
    }
    
    private static int64 get_photo_key(DataSource source) {
        LibraryPhoto photo = (LibraryPhoto) source;
        PhotoID photo_id = photo.get_photo_id();
        
        return photo_id.id;
    }
    
    public LibraryPhoto fetch(PhotoID photo_id) {
        return (LibraryPhoto) fetch_by_key(photo_id.id);
    }
}

//
// LibraryPhoto
//

public class LibraryPhoto : Photo {
    // Top 16 bits are reserved for TransformablePhoto
    private const uint64 FLAG_HIDDEN =      0x0000000000000001;
    private const uint64 FLAG_FAVORITE =    0x0000000000000002;
    
    public static LibraryPhotoSourceCollection global = null;
    
    private static MimicManager mimic_manager = null;
    
    private bool block_thumbnail_generation = false;
    private OneShotScheduler thumbnail_scheduler = null;

    private LibraryPhoto(PhotoRow row) {
        base (row);
        
        thumbnail_scheduler = new OneShotScheduler("LibraryPhoto", generate_thumbnails);
    }
    
    public static void init(ProgressMonitor? monitor = null) {
        global = new LibraryPhotoSourceCollection();
        mimic_manager = new MimicManager(global, AppDirs.get_data_subdir("mimics"));
        
        // prefetch all the photos from the database and add them to the global collection ...
        // do in batches to take advantage of add_many()
        Gee.ArrayList<PhotoRow?> all = PhotoTable.get_instance().get_all();
        Gee.ArrayList<LibraryPhoto> all_photos = new Gee.ArrayList<LibraryPhoto>();
        int count = all.size;
        for (int ctr = 0; ctr < count; ctr++)
            all_photos.add(new LibraryPhoto(all.get(ctr)));
        
        global.add_many(all_photos, monitor);
    }
    
    public static void terminate() {
    }
    
    // This accepts a PhotoRow that was prepared with TransformablePhoto.prepare_for_import and
    // has not already been inserted in the database.  See PhotoTable.add() for which fields are
    // used and which are ignored.  The PhotoRow itself will be modified with the remaining values
    // as they are stored in the database.
    public static ImportResult import(ref PhotoRow photo_row, Thumbnails thumbnails, out LibraryPhoto photo) {
        // add to the database
        PhotoID photo_id = PhotoTable.get_instance().add(ref photo_row);
        if (photo_id.is_invalid())
            return ImportResult.DATABASE_ERROR;
        
        // create local object but don't add to global until thumbnails generated
        photo = new LibraryPhoto(photo_row);
        
        try {
            ThumbnailCache.import_thumbnails(photo_id, thumbnails, true);
        } catch (Error err) {
            warning("Unable to create thumbnails for %s: %s", photo_row.filepath, err.message);
            
            PhotoTable.get_instance().remove(photo_id);
            
            return ImportResult.convert_error(err, ImportResult.DECODE_ERROR);
        }
        
        global.add(photo);
        
        return ImportResult.SUCCESS;
    }
    
    private void generate_thumbnails() {
        try {
            ThumbnailCache.import_from_source(get_photo_id(), this, true);
        } catch (Error err) {
            warning("Unable to generate thumbnails for %s: %s", to_string(), err.message);
        }
        
        // fire signal that thumbnails have changed
        notify_thumbnail_altered();
    }
    
    private override void altered () {
        // generate new thumbnails in the background
        if (!block_thumbnail_generation)
            thumbnail_scheduler.at_priority_idle(Priority.LOW);
        
        base.altered();
    }

    public override Gdk.Pixbuf get_preview_pixbuf(Scaling scaling) throws Error {
        Gdk.Pixbuf pixbuf = get_thumbnail(ThumbnailCache.Size.BIG);
        
        return scaling.perform_on_pixbuf(pixbuf, Gdk.InterpType.NEAREST, true);
    }
    
    public override void rotate(Rotation rotation) {
        // block thumbnail generation for this operation; taken care of below
        block_thumbnail_generation = true;
        base.rotate(rotation);
        block_thumbnail_generation = false;

        // because rotations are (a) common and available everywhere in the app, (b) the user expects
        // a level of responsiveness not necessarily required by other modifications, (c) can be
        // performed on multiple images simultaneously, and (d) can't cache a lot of full-sized
        // pixbufs for rotate-and-scale ops, perform the rotation directly on the already-modified 
        // thumbnails.
        try {
            ThumbnailCache.rotate(get_photo_id(), rotation);
        } catch (Error err) {
            // TODO: Mark thumbnails as dirty in database
            warning("Unable to update thumbnails for %s: %s", to_string(), err.message);
        }
        
        notify_thumbnail_altered();
    }
    
    // Returns unscaled thumbnail with all modifications applied applicable to the scale
    public override Gdk.Pixbuf? get_thumbnail(int scale) throws Error {
        return ThumbnailCache.fetch(get_photo_id(), scale);
    }
    
    public LibraryPhoto duplicate() throws Error {
        // clone the backing file
        File dupe_file = LibraryFiles.duplicate(get_file(), on_duplicate_progress);
        
        // clone the row in the database so another that relies on this new backing file
        PhotoID dupe_id = PhotoTable.get_instance().duplicate(get_photo_id(), dupe_file.get_path());
        PhotoRow dupe_row = PhotoTable.get_instance().get_row(dupe_id);
        
        // clone thumbnails
        ThumbnailCache.duplicate(get_photo_id(), dupe_id);
        
        // build the DataSource for the duplicate
        LibraryPhoto dupe = new LibraryPhoto(dupe_row);
        
        // add it to the SourceCollection; this notifies everyone interested of its presence
        global.add(dupe);
        
        return dupe;
    }
    
    private void on_duplicate_progress(int64 current, int64 total) {
        spin_event_loop();
    }
    
    public bool is_favorite() {
        return is_flag_set(FLAG_FAVORITE);
    }
    
    public void set_favorite(bool favorite) {
        if (favorite)
            add_remove_flags(FLAG_FAVORITE, FLAG_HIDDEN);
        else
            remove_flags(FLAG_FAVORITE);
    }
    
    public bool is_hidden() {
        return is_flag_set(FLAG_HIDDEN);
    }
    
    public void set_hidden(bool hidden) {
        if (hidden)
            add_remove_flags(FLAG_HIDDEN, FLAG_FAVORITE);
        else
            remove_flags(FLAG_HIDDEN);
    }
    
    public override bool internal_delete_backing() throws Error {
        delete_original_file();
        
        return true;
    }
    
    public override void destroy() {
        PhotoID photo_id = get_photo_id();

        // remove all cached thumbnails
        ThumbnailCache.remove(photo_id);
        
        // remove from photo table -- should be wiped from storage now (other classes may have added
        // photo_id to other parts of the database ... it's their responsibility to remove them
        // when removed() is called)
        PhotoTable.get_instance().remove(photo_id);
        
        base.destroy();
    }
    
    private void delete_original_file() {
        File file = get_file();
        
        try {
            file.trash(null);
        } catch (Error err) {
            // log error but don't abend, as this is not fatal to operation (also, could be
            // the photo is removed because it could not be found during a verify)
            message("Unable to delete original photo %s: %s", file.get_path(), err.message);
        }
        
        // remove empty directories corresponding to imported path, but only if file is located
        // inside the user's Pictures directory
        if (file.has_prefix(AppDirs.get_photos_dir())) {
            File parent = file;
            for (int depth = 0; depth < LibraryFiles.DIRECTORY_DEPTH; depth++) {
                parent = parent.get_parent();
                if (parent == null)
                    break;
                
                try {
                    if (!query_is_directory_empty(parent))
                        break;
                } catch (Error err) {
                    warning("Unable to query file info for %s: %s", parent.get_path(), err.message);
                    
                    break;
                }
                
                try {
                    parent.delete(null);
                    debug("Deleted empty directory %s", parent.get_path());
                } catch (Error err) {
                    // again, log error but don't abend
                    message("Unable to delete empty directory %s: %s", parent.get_path(),
                        err.message);
                }
            }
        }
    }
}

//
// DirectPhoto
//

public class DirectPhotoSourceCollection : DatabaseSourceCollection {
    private Gee.HashMap<File, DirectPhoto> file_map = new Gee.HashMap<File, DirectPhoto>(file_hash, 
        file_equal, direct_equal);
    
    public DirectPhotoSourceCollection() {
        base("DirectPhotoSourceCollection", get_direct_key);
    }
    
    private static int64 get_direct_key(DataSource source) {
        DirectPhoto photo = (DirectPhoto) source;
        PhotoID photo_id = photo.get_photo_id();
        
        return photo_id.id;
    }
    
    public override void notify_items_added(Gee.Iterable<DataObject> added) {
        foreach (DataObject object in added) {
            DirectPhoto photo = (DirectPhoto) object;
            File file = photo.get_file();
            
            assert(!file_map.has_key(file));
            
            file_map.set(file, photo);
        }
        
        base.notify_items_added(added);
    }
    
    public override void notify_items_removed(Gee.Iterable<DataObject> removed) {
        foreach (DataObject object in removed) {
            DirectPhoto photo = (DirectPhoto) object;
            File file = photo.get_file();
            
            bool is_removed = file_map.unset(file);
            assert(is_removed);
        }
        
        base.notify_items_removed(removed);
    }
    
    public DirectPhoto? fetch(File file, bool reset = false) throws Error {
        // fetch from the map first, which ensures that only one DirectPhoto exists for each file
        DirectPhoto? photo = file_map.get(file);
        if (photo != null) {
            // if a reset is necessary, the database (and the object) need to reset to original
            // easiest way to do this: perform an update, which is a kind of in-place re-import
            if (reset)
                photo.update();
            
            return photo;
        }
            
        // for DirectPhoto, a fetch on an unknown file is an implicit import into the in-memory
        // database (which automatically adds the new DirectPhoto object to DirectPhoto.global,
        // which be us)
        return DirectPhoto.internal_import(file);
    }
    
    public DirectPhoto? get_file_source(File file) {
        return file_map.get(file);
    }
}

public class DirectPhoto : Photo {
    private const int PREVIEW_BEST_FIT = 360;
    
    public static DirectPhotoSourceCollection global = null;
    
    private Gdk.Pixbuf preview = null;
    
    private DirectPhoto(PhotoRow row) {
        base (row);
    }
    
    public static void init() {
        global = new DirectPhotoSourceCollection();
    }
    
    public static void terminate() {
    }
    
    // This method should only be called by DirectPhotoSourceCollection.  Use
    // DirectPhoto.global.fetch to import files into the system.
    public static DirectPhoto? internal_import(File file) {
        PhotoRow photo_row;
        ImportResult result = TransformablePhoto.prepare_for_import(file, 
            PhotoTable.get_instance().generate_import_id(), PhotoFileSniffer.Options.NO_MD5, 
            out photo_row, null);
        if (result != ImportResult.SUCCESS) {
            // this should never happen; DirectPhotoSourceCollection guarantees it.
            assert(result != ImportResult.PHOTO_EXISTS);
            
            return null;
        }
        
        PhotoTable.get_instance().add(ref photo_row);
        
        // create DataSource and add to SourceCollection
        DirectPhoto photo = new DirectPhoto(photo_row);
        global.add(photo);
        
        return photo;
    }
    
    public override Gdk.Pixbuf get_preview_pixbuf(Scaling scaling) throws Error {
        if (preview == null)
            preview = get_thumbnail(PREVIEW_BEST_FIT);
        
        return scaling.perform_on_pixbuf(preview, Gdk.InterpType.BILINEAR, true);
    }
    
    public override Gdk.Pixbuf? get_thumbnail(int scale) throws Error {
        return get_pixbuf(Scaling.for_best_fit(scale, false));
    }
    
    private override void altered() {
        preview = null;
        
        base.altered();
    }
}

