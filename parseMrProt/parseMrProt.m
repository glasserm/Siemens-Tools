function [mrProt, zeroList] = parseMrProt(inputArg)
% parseMrProt - Parses MrProt from a DICOM acquired on a Siemens VB, VD, or
% VE line MRI scanner.
%
% Usage:  mrprot = parseMrProt(input)
%        [mrprot, zeroList] = parseMrProt(input)
% The input argument can be either the file location of the DICOM, or the
% DICOM header as provided by the MATLAB function dicominfo. The resulting 
% structure includes all fields included in MrProt, nested and indexed.
%
% XA and newer Siemens DICOMS are not supported as they do not include
% MrProt in the same way. 
% 
% Note that field indexes may not correspond to those in the native MrProt 
% as some Siemens arrays are numbered starting at 0, and others at 1. As a
% result, all indexes are renumbered from 1 to comply with MATLAB
% requirements. Those that are renumbered will be off by one. The optional 
% return  zeroList includes a list of all the renumbered fields. These 
% fields are usually nested below a parent field name.

%Author: Jeffrey Luci, jeffrey.luci@rutgers.edu
%VERSION HISTORY:
%20230201 - Initial Release
%20230220 - Added sxupport for enhanced DICOMs, including the highly
%           questionable choice by Siemens to use numbers as structure
%           field names in some (inconsistent) cases. This made it
%           necessary to convert hex values to decimal as opposed to
%           maintaining the ascii encoded hex value which was the 
%           convention in the previous version.   

%check to see if the input is a dicom or a header structure
if ischar(inputArg)
    if contains(inputArg, 'ASCCONV')
        tagFullText = inputArg;
    elseif isdicom(inputArg)
        hdr = dicominfo(inputArg);
    end
else
    if isstruct(inputArg)
        hdr = inputArg;
    end
end

if ~exist('tagFullText', 'var')
    if isfield(hdr, 'Private_0029_1020')
        tagFullText = char(hdr.Private_0029_1020)';
    elseif isfield(hdr, 'Private_0029_1120')
        tagFullText = char(hdr.Private_0029_1120)';
    elseif isfield(hdr, 'SharedFunctionalGroupsSequence')
        tagFullText = char(hdr.SharedFunctionalGroupsSequence.Item_1.Private_0021_10fe.Item_1.Private_0021_1019)';
    else
        error('No DICOM tag with MrProt located.');
    end
end

clear('inputArg');


% if ~isstruct(inputArg)
%     if isdicom(inputArg)
%         hdr = dicominfo(inputArg);
%         if isfield(hdr, 'AcquisitionContextSequence') %only exists in enhanced DICOMs
%             error([inputArg, ' is an enhanced DICOM. MrProt is not included.']);
%         end
%     end
% else
%     if ~isfield(inputArg, 'Format')
%         error('This does not appear to be a DICOM header structure.');
%     end
%     hdr = inputArg;
%     clear('inputArg');
% end

%initialize mrProt
mrProt = struct;

%create text list that records which arrays' numbering start at 0 instead of 1
zeroList = '';

%extract text of proprietary tag (0029,1020) or (0029,1120) - whichever exists
% if isfield(hdr, 'Private_0029_1020')
%     tagFullText = char(hdr.Private_0029_1020)';
% elseif isfield(hdr, 'Private_0029_1120')
%     tagFullText = char(hdr.Private_0029_1120)';
% else
%     error('No DICOM tag with MrProt located.');
% end

%find beginning of mrprot in the text stream
locationsCR  = strfind(tagFullText, newline);
startString = strfind(tagFullText, 'ASCCONV BEGIN');

lastSkippedCR = find(locationsCR > startString, 1 );
startOfMrProt = locationsCR(lastSkippedCR) + 1;

%find end of mrprot in the text stream
endString = strfind(tagFullText, 'ASCCONV END');
lastKeptCR = find(locationsCR < endString, 1, 'last' );
endOfMrProt = locationsCR(lastKeptCR);

%Strip off all extra text, leaving only mrprot
mrProtText = tagFullText(startOfMrProt:endOfMrProt);
mrProtText = [newline, mrProtText, newline];            %add CR to start and end
mrProtText = replace(mrProtText, char(9), '');          %strip tabs
mrProtText = replace(mrProtText, '""', '"');            %strip escaped double quotes
mrProtText = replace(mrProtText, '__', '');             %strip out __
mrProtLocationsCR = strfind(mrProtText, newline);

for ii = 1:numel(mrProtLocationsCR)-2                   % minus 2 accounts for added CRs in previous block
    %select next line of text, format it, and split opposite '='
    curLine = mrProtText(mrProtLocationsCR(ii):mrProtLocationsCR(ii+1));
    curLine = curLine(2:end-1);                         %strip out leading/trailing CR

    %yank comments out of each line
    curLine = strsplit(curLine, '#');
    curLine = strtrim(curLine{1});
    if isempty(curLine)
        continue;
    end

    %begin parsing now
    curLineSplit = strtrim(strsplit(curLine, '='));
    assignmentVar = strsplit(curLineSplit{1}, '.');

    %fix Siemens STUPID use of numbers as field names
    % add number in square brackets to end of last fieldname to maintain
    % consistency with every other time Siemens uses an arrayed field.
    if ~isnan(str2double(assignmentVar{end}))
        assignmentVar{end-1} = [assignmentVar{end-1},'[', assignmentVar{end}, ']'];
        assignmentVar(end) = [];
    end

    for jj = 1:numel(assignmentVar)
        %parse structure format of left side assignment
        if contains(assignmentVar{1,jj}, '[')
            assignmentVar{2,jj} = {str2double(regexp(assignmentVar{1,jj}, '\d\d?\d?\d?(?=\])', 'match'))};
            assignmentVar{1,jj} = cell2mat(regexp(assignmentVar{1,jj}, '^[^\[]+', 'match'));
            %check to see if the array index needs to be renumbered
            if cell2mat(assignmentVar{2,jj}) == 0 || contains(zeroList, assignmentVar{1,jj})
                assignmentVar{2,jj} = {cell2mat(assignmentVar{2,jj}) + 1};
                if ~contains(zeroList, assignmentVar{1,jj})
                    zeroList = [zeroList, assignmentVar{1,jj}, newline];
                end
            end
        else
            assignmentVar{2,jj} = {1};
        end
    end
    %check if this is a struct size initializer. If so, skip it.
    if strcmp(assignmentVar{1,end}, 'size')
        continue
    end

    %Convert hex to decimal
    if contains(curLineSplit{2}, '0x')
        curLineSplit{2} = {num2str(hex2dec(curLineSplit{2}))};
    end


    %Determine if right side is string or not, make appropriate assigment
    if contains(curLineSplit{2}, '"')
        assignmentVar{end} = {1:length(curLineSplit{2})};
        mrProt = setfield(mrProt, assignmentVar{:}, curLineSplit{2});
    else
        mrProt = setfield(mrProt, assignmentVar{:}, str2double(curLineSplit{2}));
    end
end

% make sure zeroList exists, even if empty
if ~isempty(zeroList)
    zeroList = strtrim(zeroList);
end

end
